/**
 * Session factory for the ring-sip-bridge sidecar.
 *
 * The production factory drives ``ring-client-api``: we authenticate with
 * the caller-supplied refresh token, find the requested camera, and ask
 * ``camera.streamVideo`` to spin up an ffmpeg process that receives the
 * RTP tracks from Ring and publishes the result as RTSP to mediamtx.
 * From mediamtx's point of view the stream arrives exactly the way the
 * ffmpeg test pattern does, so the existing HLS / WHEP surfaces work
 * without any further changes.
 *
 * Tests (`npm test`) inject a custom factory via ``sessionFactory`` on
 * ``buildApp`` so the full sidecar surface runs offline (Req 6.1, 6.5,
 * 6.6, 6.8).
 */

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
 * @property {string} rtspPath      e.g. "ring/<device_id>"
 * @property {boolean} hasAudio
 * @property {string} state         "active" | "terminated"
 * @property {number} startedAt     ms since epoch
 * @property {() => Promise<void>} stop
 * @property {(cb: () => void) => void} onTerminated
 */

/**
 * Build the ffmpeg output args that publish the Ring live feed to
 * mediamtx via RTSP. Mirrors the pattern in ring-client-api's own docs:
 * a single output target using the RTSP muxer with TCP transport so the
 * publish survives UDP-hostile networks.
 */
function buildRtspOutputArgs(mediamtxRtspUrl, deviceId) {
    const base = mediamtxRtspUrl.replace(/\/$/, '');
    return [
        '-rtsp_transport', 'tcp',
        '-f', 'rtsp',
        `${base}/${deviceId}`,
    ];
}

export function createSessionFactory({ mediamtxRtspUrl }) {
    return {
        /**
         * Start a new SIP session for the given device.
         *
         * @param {{ deviceId: string, refreshToken: string, bridgeSessionId: string }} opts
         * @returns {Promise<RingCameraSession>}
         */
        async start({ deviceId, refreshToken, bridgeSessionId }) {
            // Construct a per-session RingApi instance. The refresh token
            // is only held inside this closure for the lifetime of the
            // call; we never persist it (Req 6.6).
            const ringApi = new RingApi({
                refreshToken,
                cameraStatusPollingSeconds: 600,
                controlCenterDisplayName: 'ring-sip-bridge',
            });

            const cameras = await ringApi.getCameras();
            dbg(`cameras.length=${cameras.length} looking_for=${deviceId}`);
            const camera = cameras.find((c) => String(c.id) === String(deviceId));
            if (!camera) {
                throw new Error(`camera ${deviceId} not visible to ring account`);
            }
            dbg(`matched camera id=${camera.id} name=${camera.name}`);

            const rtspPath = `ring/${deviceId}`;
            const output = buildRtspOutputArgs(mediamtxRtspUrl, deviceId);
            dbg(`starting live call; ffmpeg output args=${JSON.stringify(output)}`);

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
                    '-rtbufsize', '100M',
                    '-max_delay', '500000',
                    '-analyzeduration', '15000000',
                    '-probesize', '10000000',
                    '-fflags', '+genpts+discardcorrupt',
                ],
                video: ['-vcodec', 'copy', '-bsf:v', 'dump_extra=freq=keyframe'],
                audio: ['-acodec', 'aac', '-ar', '44100', '-ac', '2', '-b:a', '128k'],
                output,
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
                        // Swallow: the only path forward is to drop our
                        // entry and let Ring's SIP timeout reap any
                        // residue on their side.
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
        async start({ deviceId, refreshToken, bridgeSessionId }) {
            if (startBehavior === 'fail') {
                throw new Error('ring sip negotiation failed (test)');
            }
            const listeners = [];
            const session = {
                deviceId,
                rtspPath: `ring/${deviceId}`,
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
