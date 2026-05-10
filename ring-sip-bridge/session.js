/**
 * Session factory for the ring-sip-bridge sidecar.
 *
 * Uses ring-client-api's ``camera.streamVideo`` with a post-construction
 * monkey-patch on the StreamingSession's video splitter to insert a jitter
 * buffer. This reorders out-of-sequence RTP packets before they hit
 * ffmpeg's SDP demuxer, fixing the "max delay reached / RTP missed N
 * packets" issue that prevented video frames from being emitted.
 */

import fs from 'node:fs';
import path from 'node:path';
import dgram from 'node:dgram';
import { RingApi } from 'ring-client-api';
import { enableDebug, useLogger } from 'ring-client-api/util';
import { JitterBuffer } from './jitter-buffer.js';

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
 * Build the ffmpeg output args for RTSP (legacy mediamtx path).
 */
function buildRtspOutputArgs(mediamtxRtspUrl, deviceId) {
    const base = mediamtxRtspUrl.replace(/\/$/, '');
    return ['-rtsp_transport', 'tcp', '-f', 'rtsp', `${base}/${deviceId}`];
}

/**
 * Build the ffmpeg output args for HLS / fMP4.
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
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* */ }
    fs.mkdirSync(dir, { recursive: true });
    return dir;
}

export function createSessionFactory({ mediamtxRtspUrl, hlsRoot }) {
    return {
        async start({ deviceId, refreshToken, bridgeSessionId, output = 'rtsp' }) {
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
                if (!hlsRoot) throw new Error('hlsRoot not configured');
                const dir = ensureHlsDir(hlsRoot, String(deviceId));
                outputArgs = buildHlsOutputArgs(dir);
                hlsPath = `/hls/${deviceId}/index.m3u8`;
                rtspPath = '';
                dbg(`hls output dir=${dir}`);
            } else {
                outputArgs = buildRtspOutputArgs(mediamtxRtspUrl, String(deviceId));
                dbg(`rtsp output args=${JSON.stringify(outputArgs)}`);
            }

            // Use streamVideo which handles the full SDP/ffmpeg pipeline,
            // but with our custom input flags for better buffering.
            const liveCall = await camera.streamVideo({
                input: [
                    '-rtbufsize', '512M',
                    '-max_delay', '5000000',
                    '-analyzeduration', '15000000',
                    '-probesize', '10000000',
                    '-fflags', '+genpts+discardcorrupt',
                ],
                video: ['-vcodec', 'copy', '-bsf:v', 'dump_extra=freq=keyframe'],
                audio: ['-acodec', 'aac', '-ar', '44100', '-ac', '2', '-b:a', '128k'],
                output: outputArgs,
            });
            dbg(`live call started bridge_session_id=${bridgeSessionId}`);

            // --- JITTER BUFFER PATCH ---
            // After streamVideo starts, the StreamingSession's internal
            // videoSplitter is already forwarding RTP to ffmpeg's UDP port.
            // We intercept by replacing the videoSplitter's send method
            // with one that buffers and reorders before forwarding.
            //
            // Access the private videoSplitter (JS runtime allows it even
            // though TypeScript marks it private).
            const videoSplitter = liveCall.videoSplitter;
            if (videoSplitter) {
                const originalSend = videoSplitter.send.bind(videoSplitter);
                const jb = new JitterBuffer({
                    flushIntervalMs: 60,
                    send: (buf) => originalSend(buf, { port: videoSplitter._port }),
                });

                // Override the splitter's send to route through our buffer.
                // The RTP observable calls splitter.send(serialized, {port}).
                // We capture the port on first call and route through the JB.
                let capturedPort = null;
                videoSplitter.send = (buf, opts) => {
                    if (!capturedPort && opts?.port) capturedPort = opts.port;
                    // Deserialize to get sequence number for reordering
                    try {
                        const { RtpPacket } = require('werift');
                        const pkt = RtpPacket.deSerialize(buf);
                        jb.push(pkt);
                    } catch {
                        // If deserialization fails, forward directly
                        return originalSend(buf, opts);
                    }
                    return Promise.resolve();
                };

                // Fix the JB's send to use the captured port
                const origJBSend = jb._send;
                jb._send = (buf) => {
                    if (capturedPort) {
                        return originalSend(buf, { port: capturedPort });
                    }
                    return origJBSend(buf);
                };

                // Store for cleanup
                liveCall._jitterBuffer = jb;
                dbg('jitter buffer installed on videoSplitter');
            }

            // Periodically request key frames
            const keyFrameTimer = setInterval(() => {
                try { liveCall.requestKeyFrame(); } catch { /* */ }
            }, 3000);

            const listeners = [];
            const session = {
                deviceId, rtspPath, hlsPath,
                hasAudio: true,
                state: 'active',
                startedAt: Date.now(),
                bridgeSessionId,
                async stop() {
                    if (this.state === 'terminated') return;
                    this.state = 'terminated';
                    clearInterval(keyFrameTimer);
                    if (liveCall._jitterBuffer) liveCall._jitterBuffer.stop();
                    try { liveCall.stop(); } catch (err) {
                        console.error(`liveCall.stop failed bridge=${bridgeSessionId} err=${err?.message}`);
                    }
                },
                onTerminated(cb) { listeners.push(cb); },
            };

            liveCall.onCallEnded.subscribe(() => {
                clearInterval(keyFrameTimer);
                if (liveCall._jitterBuffer) liveCall._jitterBuffer.stop();
                session.state = 'terminated';
                for (const cb of listeners) {
                    try { cb(); } catch (err) {
                        console.error(`termination listener failed bridge=${bridgeSessionId} err=${err?.message}`);
                    }
                }
            });

            return session;
        },
    };
}

/**
 * Fake session factory for tests.
 */
export function createTestSessionFactory(opts = {}) {
    const { startBehavior = 'ok', hasAudio = true, terminationDelayMs = 0 } = opts;
    return {
        async start({ deviceId, refreshToken, bridgeSessionId, output = 'rtsp' }) {
            if (startBehavior === 'fail') throw new Error('ring sip negotiation failed (test)');
            const listeners = [];
            const session = {
                deviceId,
                rtspPath: output === 'rtsp' ? `ring/${deviceId}` : '',
                hlsPath: output === 'hls' ? `/hls/${deviceId}/index.m3u8` : null,
                hasAudio, state: 'active', startedAt: Date.now(), bridgeSessionId,
                _terminationListeners: listeners,
                async stop() { this.state = 'terminated'; },
                onTerminated(cb) { listeners.push(cb); },
                simulateRingTermination() {
                    this.state = 'terminated';
                    for (const cb of listeners) cb();
                },
            };
            if (terminationDelayMs > 0) {
                setTimeout(() => session.simulateRingTermination(), terminationDelayMs).unref();
            }
            void refreshToken;
            return session;
        },
    };
}
