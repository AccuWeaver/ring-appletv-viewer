/**
 * Session factory for the ring-sip-bridge sidecar.
 *
 * The production factory drives ``ring-client-api``: we authenticate with
 * the caller-supplied refresh token, find the requested camera, and ask
 * ``camera.streamVideo`` to spin up an ffmpeg process that receives the
 * RTP tracks from Ring. On request the factory can target two different
 * outputs:
 *
 *   * RTSP (default) — the legacy path that publishes to mediamtx.
 *   * HLS — writes fMP4 segments directly into a well-known directory
 *     the HTTP server can then serve to clients such as the tvOS
 *     simulator. This path avoids the ICE and RTSP quirks we ran into
 *     with go2rtc and mediamtx and is the recommended production
 *     configuration.
 *
 * The output target is selected per-session by ``output: 'rtsp' | 'hls'``
 * in the ``start`` options.
 *
 * Tests (`npm test`) inject a custom factory via ``sessionFactory`` on
 * ``buildApp`` so the full sidecar surface runs offline.
 */

import fs from 'node:fs';
import path from 'node:path';
import { RingApi } from 'ring-client-api';
import { enableDebug, useLogger } from 'ring-client-api/util';

// Gate verbose session logs behind RING_SIP_BRIDGE_DEBUG=1 so the default
// container output stays clean.
const DEBUG = process.env.RING_SIP_BRIDGE_DEBUG === '1';
function dbg(...args) { if (DEBUG) console.log('[sip-bridge]', ...args); }
if (DEBUG) {
    enableDebug();
    useLogger({
        logInfo: (...args) => console.log('[ring-client-api]', ...args),
        logError: (message) => console.error('[ring-client-api]', message),
    });
}

/**
 * @typedef {Object} RingCameraSession
 * @property {string} deviceId
 * @property {string} rtspPath          e.g. "ring/<device_id>"  (rtsp target only)
 * @property {string | null} hlsPath    e.g. "/hls/<device_id>/index.m3u8"  (hls target only)
 * @property {boolean} hasAudio
 * @property {string} state             "active" | "terminated"
 * @property {number} startedAt         ms since epoch
 * @property {() => Promise<void>} stop
 * @property {(cb: () => void) => void} onTerminated
 */

/**
 * Build the ffmpeg output args that publish the Ring live feed to
 * mediamtx via RTSP. Used when ``output: 'rtsp'`` is selected.
 */
function buildRtspOutputArgs(mediamtxRtspUrl, deviceId) {
    const base = mediamtxRtspUrl.replace(/\/$/, '');
    return [
        '-rtsp_transport', 'tcp',
        '-f', 'rtsp',
        `${base}/${deviceId}`,
    ];
}

/**
 * Build the ffmpeg output args for HLS / fMP4. Writes an ``index.m3u8``
 * playlist and a ring buffer of segment files into the per-device
 * directory. Used when ``output: 'hls'`` is selected.
 *
 * The flag soup:
 *   - ``-f hls``: HLS muxer.
 *   - ``-hls_time 2``: 2-second target segment duration. AVPlayer's
 *     adaptive engine handles shorter segments fine; 2s keeps
 *     glass-to-glass latency near 4-6 s.
 *   - ``-hls_list_size 6``: keep six segments on the playlist so AVPlayer
 *     has room for startup buffer.
 *   - ``-hls_flags delete_segments+append_list+discont_start+independent_segments``:
 *     classic live-HLS flags — autovac old segments, support playlist
 *     truncation, mark each segment as independent to let AVPlayer
 *     start anywhere.
 *   - ``-hls_segment_type fmp4``: fragmented MP4 instead of MPEG-TS.
 *     tvOS / iOS AVPlayer strongly prefers fMP4; fMP4 also supports
 *     H.265 if we ever want to pass HEVC through.
 *   - ``-hls_fmp4_init_filename init.mp4``: standard name for the init
 *     segment.
 *   - ``-hls_segment_filename segment-%d.m4s``: match what the playlist
 *     will reference (URL-relative).
 *   - ``-movflags ... empty_moov+default_base_moof``: required for
 *     streaming fMP4 segments in the HLS muxer.
 */
function buildHlsOutputArgs(hlsDir) {
    const playlist = path.join(hlsDir, 'index.m3u8');
    const segmentPattern = path.join(hlsDir, 'segment-%d.m4s');
    return [
        '-f', 'hls',
        '-hls_time', '2',
        '-hls_list_size', '6',
        '-hls_flags', 'delete_segments+append_list+discont_start+independent_segments',
        '-hls_segment_type', 'fmp4',
        '-hls_fmp4_init_filename', 'init.mp4',
        '-hls_segment_filename', segmentPattern,
        '-movflags', '+frag_keyframe+empty_moov+default_base_moof',
        playlist,
    ];
}

function ensureHlsDir(hlsRoot, deviceId) {
    const dir = path.join(hlsRoot, deviceId);
    // Wipe any stale segments from a prior session so AVPlayer never
    // picks up half-written files from the last run.
    try {
        fs.rmSync(dir, { recursive: true, force: true });
    } catch { /* empty */ }
    fs.mkdirSync(dir, { recursive: true });
    return dir;
}

export function createSessionFactory({ mediamtxRtspUrl, hlsRoot }) {
    return {
        /**
         * Start a new SIP session for the given device.
         *
         * @param {{
         *   deviceId: string,
         *   refreshToken: string,
         *   bridgeSessionId: string,
         *   output?: 'rtsp' | 'hls',
         * }} opts
         * @returns {Promise<RingCameraSession>}
         */
        async start({ deviceId, refreshToken, bridgeSessionId, output = 'rtsp' }) {
            // Construct a per-session RingApi instance. The refresh token
            // is only held inside this closure for the lifetime of the
            // call; we never persist it.
            const ringApi = new RingApi({
                refreshToken,
                cameraStatusPollingSeconds: 600,
                controlCenterDisplayName: 'ring-sip-bridge',
            });

            const cameras = await ringApi.getCameras();
            dbg(`cameras.length=${cameras.length} looking_for=${deviceId} output=${output}`);
            const camera = cameras.find((c) => String(c.id) === String(deviceId));
            if (!camera) {
                throw new Error(`camera ${deviceId} not visible to ring account`);
            }
            dbg(`matched camera id=${camera.id} name=${camera.name}`);

            let outputArgs;
            let hlsPath = null;
            let rtspPath = `ring/${deviceId}`;

            if (output === 'hls') {
                if (!hlsRoot) {
                    throw new Error('hlsRoot not configured on session factory');
                }
                const dir = ensureHlsDir(hlsRoot, String(deviceId));
                outputArgs = buildHlsOutputArgs(dir);
                hlsPath = `/hls/${deviceId}/index.m3u8`;
                rtspPath = '';
                dbg(`hls output dir=${dir} path=${hlsPath}`);
            } else {
                outputArgs = buildRtspOutputArgs(mediamtxRtspUrl, String(deviceId));
                dbg(`rtsp output args=${JSON.stringify(outputArgs)}`);
            }

            // streamVideo = startLiveCall + startTranscoding. The
            // returned StreamingSession tracks the ffmpeg + SIP lifetime
            // and exposes ``onCallEnded`` for teardown propagation.
            //
            // ffmpeg options:
            //   * ``input`` gives the SDP demuxer enough buffer and probe
            //     budget to identify Ring's H.264 stream before ffmpeg
            //     gives up (analyzeduration + probesize + rtbufsize).
            //   * ``video`` copies H.264 and uses the ``dump_extra`` bsf
            //     to inject SPS/PPS on every keyframe so HLS clients
            //     downstream can pick up stream dimensions without
            //     waiting for an out-of-band side channel.
            //   * ``audio`` transcodes Ring's opus to AAC LC so the
            //     resulting HLS stream plays in AVPlayer on tvOS.
            const liveCall = await camera.streamVideo({
                input: [
                    '-rtbufsize', '512M',
                    '-buffer_size', '16777216',
                    '-max_delay', '5000000',
                    '-reorder_queue_size', '2048',
                    '-analyzeduration', '15000000',
                    '-probesize', '10000000',
                    '-fflags', '+genpts+discardcorrupt',
                    '-use_wallclock_as_timestamps', '1',
                    '-thread_queue_size', '4096',
                ],
                video: ['-vcodec', 'copy', '-bsf:v', 'dump_extra=freq=keyframe'],
                audio: ['-acodec', 'aac', '-ar', '44100', '-ac', '2', '-b:a', '128k'],
                output: outputArgs,
            });
            dbg(`live call started bridge_session_id=${bridgeSessionId}`);

            // Periodically nudge Ring for a new key frame. Without this,
            // if the first key frame gets dropped/mis-timed, ffmpeg
            // never emits a video frame and the HLS muxer never has
            // enough data to serve a playlist.
            const keyFrameTimer = setInterval(() => {
                try {
                    liveCall.requestKeyFrame();
                } catch {
                    // Session may already be torn down.
                }
            }, 3000);

            const listeners = [];
            const session = {
                deviceId,
                rtspPath,
                hlsPath,
                hasAudio: true,
                state: 'active',
                startedAt: Date.now(),
                bridgeSessionId,
                async stop() {
                    if (this.state === 'terminated') return;
                    this.state = 'terminated';
                    clearInterval(keyFrameTimer);
                    try {
                        liveCall.stop();
                    } catch (err) {
                        console.error(
                            `liveCall.stop failed bridge_session_id=${bridgeSessionId} ` +
                                `device_id=${deviceId} error=${err?.message}`
                        );
                    }
                },
                onTerminated(cb) {
                    listeners.push(cb);
                },
            };

            // Propagate Ring-side termination (call ended by Ring, SIP
            // disconnect, etc.) so the Express layer can clean its map.
            liveCall.onCallEnded.subscribe(() => {
                clearInterval(keyFrameTimer);
                session.state = 'terminated';
                for (const cb of listeners) {
                    try { cb(); } catch (err) {
                        console.error(
                            `termination listener failed ` +
                                `bridge_session_id=${bridgeSessionId} error=${err?.message}`
                        );
                    }
                }
            });

            return session;
        },
    };
}

/**
 * Fake session factory for tests.
 *
 * Returns an object matching the same contract as the production
 * factory, but with extra hooks that let tests simulate specific
 * failure modes: SIP start failure, audio-absent streams, and
 * Ring-initiated mid-stream termination.
 */
export function createTestSessionFactory(opts = {}) {
    const { startBehavior = 'ok', hasAudio = true, terminationDelayMs = 0 } = opts;
    return {
        async start({ deviceId, refreshToken, bridgeSessionId, output = 'rtsp' }) {
            if (startBehavior === 'fail') {
                throw new Error('ring sip negotiation failed (test)');
            }
            const listeners = [];
            const session = {
                deviceId,
                rtspPath: output === 'rtsp' ? `ring/${deviceId}` : '',
                hlsPath: output === 'hls' ? `/hls/${deviceId}/index.m3u8` : null,
                hasAudio,
                state: 'active',
                startedAt: Date.now(),
                bridgeSessionId,
                _terminationListeners: listeners,
                async stop() {
                    this.state = 'terminated';
                },
                onTerminated(cb) {
                    listeners.push(cb);
                },
                /** Test-only: fire the Ring-side termination watchdog. */
                simulateRingTermination() {
                    this.state = 'terminated';
                    for (const cb of listeners) cb();
                },
            };
            if (terminationDelayMs > 0) {
                setTimeout(() => session.simulateRingTermination(), terminationDelayMs).unref();
            }
            // Discard refreshToken immediately to match the production contract.
            void refreshToken;
            return session;
        },
    };
}
