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
        '-hls_time', '4',
        '-hls_list_size', '6',
        '-hls_flags', 'delete_segments+independent_segments',
        '-hls_segment_type', 'fmp4',
        '-hls_segment_filename', segmentPattern,
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

            // --- JITTER BUFFER ---
            // We need to intercept video RTP BEFORE streamVideo subscribes.
            // Replace the onVideoRtp Subject with a buffered version that
            // holds packets for 60ms and emits them in sequence order.
            let liveCall;
            try {
                const { Subject } = await import('rxjs');
                const { JitterBuffer } = await import('./jitter-buffer.js');
                const { RtpPacket } = await import('werift');

                liveCall = await camera.startLiveCall();
                dbg(`live call started bridge_session_id=${bridgeSessionId}`);

                // Patch: wrap onVideoRtp with our jitter buffer
                const bufferedVideoRtp = new Subject();
                const jb = new JitterBuffer({
                    flushIntervalMs: 150,
                    send: (buf) => {
                        try {
                            const pkt = RtpPacket.deSerialize(buf);
                            bufferedVideoRtp.next(pkt);
                        } catch { /* drop malformed */ }
                    },
                });

                // Subscribe to the real onVideoRtp and route through JB
                let jbPacketCount = 0;
                const jbSub = liveCall.onVideoRtp.subscribe(rtp => {
                    jbPacketCount++;
                    if (jbPacketCount <= 3 || jbPacketCount % 100 === 0) {
                        dbg(`jb received video pkt #${jbPacketCount} seq=${rtp.header.sequenceNumber}`);
                    }
                    jb.push(rtp);
                });

                // Replace the session's onVideoRtp with our buffered version
                const realOnVideoRtp = liveCall.onVideoRtp;
                liveCall.onVideoRtp = bufferedVideoRtp;

                // Now call startTranscoding with our ffmpeg options
                await liveCall.startTranscoding({
                    input: [
                        '-rtbufsize', '512M',
                        '-max_delay', '5000000',
                        '-analyzeduration', '15000000',
                        '-probesize', '10000000',
                        '-fflags', '+genpts+discardcorrupt', '-err_detect', 'ignore_err',
                    ],
                    video: ['-vcodec', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-b:v', '2M', '-g', '50'],
                    audio: ['-acodec', 'aac', '-ar', '44100', '-ac', '2', '-b:a', '128k'],
                    output: outputArgs,
                });

                // Restore for cleanup purposes
                liveCall.onVideoRtp = realOnVideoRtp;
                liveCall._jitterBuffer = jb;
                liveCall._jbSub = jbSub;
                dbg('jitter buffer active on video RTP path');
            } catch (jbErr) {
                // If jitter buffer setup fails, fall back to streamVideo
                console.error(`[sip-bridge] jitter buffer setup failed: ${jbErr?.message}`);
                console.error(jbErr?.stack);
                liveCall = await camera.streamVideo({
                    input: [
                        '-rtbufsize', '512M',
                        '-max_delay', '5000000',
                        '-analyzeduration', '15000000',
                        '-probesize', '10000000',
                        '-fflags', '+genpts+discardcorrupt', '-err_detect', 'ignore_err',
                    ],
                    video: ['-vcodec', 'libx264', '-preset', 'ultrafast', '-tune', 'zerolatency', '-b:v', '2M', '-g', '50'],
                    audio: ['-acodec', 'aac', '-ar', '44100', '-ac', '2', '-b:a', '128k'],
                    output: outputArgs,
                });
                dbg(`fallback to streamVideo bridge_session_id=${bridgeSessionId}`);
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
                    if (liveCall._jbSub) liveCall._jbSub.unsubscribe();
                    try { liveCall.stop(); } catch (err) {
                        console.error(`liveCall.stop failed bridge=${bridgeSessionId} err=${err?.message}`);
                    }
                },
                onTerminated(cb) { listeners.push(cb); },
            };

            liveCall.onCallEnded.subscribe(() => {
                clearInterval(keyFrameTimer);
                if (liveCall._jitterBuffer) liveCall._jitterBuffer.stop();
                if (liveCall._jbSub) liveCall._jbSub.unsubscribe();
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
