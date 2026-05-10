/**
 * ring-sip-bridge: HTTP control plane for Ring SIP session management.
 *
 * The Python backend calls us over HTTP to start, stop, and monitor Ring
 * SIP sessions. This file owns only the HTTP surface and session
 * bookkeeping; the real SIP negotiation lives in `./session.js` behind a
 * pluggable factory so `npm test` can drive the service with a fake
 * implementation that never touches the network.
 *
 * Two output modes are available per session:
 *
 *   - ``rtsp``: publishes the live feed to mediamtx. The legacy path.
 *   - ``hls``: writes fMP4 segments under ``/hls/<device_id>/`` and
 *     serves them via this same HTTP server so AVPlayer on tvOS can
 *     play the stream directly. Preferred for the tvOS simulator path.
 *
 * Requirements 6.1, 6.2, 6.5, 6.6, 6.8.
 */

import express from 'express';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { createSessionFactory } from './session.js';

const PORT = Number(process.env.PORT || 3000);
const MEDIAMTX_RTSP_URL = process.env.MEDIAMTX_RTSP_URL || 'rtsp://mediamtx:8554/ring';
const HLS_ROOT = process.env.HLS_ROOT || '/tmp/ring-hls';

export function buildApp({ sessionFactory, hlsRoot = HLS_ROOT } = {}) {
  // Materialize the HLS root so the static server has something to list
  // and the session factory can scope per-device directories.
  fs.mkdirSync(hlsRoot, { recursive: true });

  const factory = sessionFactory ?? createSessionFactory({
    mediamtxRtspUrl: MEDIAMTX_RTSP_URL,
    hlsRoot,
  });
  const sessions = new Map(); // bridge_session_id -> RingCameraSession

  const app = express();
  app.use(express.json({ limit: '16kb' }));

  // Serve HLS fragments with appropriate cache + content types. AVPlayer
  // will poll index.m3u8 repeatedly; we want short-TTL caching on the
  // playlist and longer caching on the segments themselves.
  app.use('/hls', (req, res, next) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    if (req.path.endsWith('.m3u8')) {
      res.setHeader('Cache-Control', 'no-cache');
    } else {
      res.setHeader('Cache-Control', 'public, max-age=2');
    }
    next();
  }, express.static(hlsRoot, {
    fallthrough: false,
    setHeaders(res, filePath) {
      if (filePath.endsWith('.m3u8')) {
        res.setHeader('Content-Type', 'application/vnd.apple.mpegurl');
      } else if (filePath.endsWith('.ts')) {
        res.setHeader('Content-Type', 'video/mp2t');
      } else if (filePath.endsWith('.m4s')) {
        res.setHeader('Content-Type', 'video/iso.segment');
      } else if (filePath.endsWith('.mp4')) {
        res.setHeader('Content-Type', 'video/mp4');
      }
    },
  }));

  // POST /sessions { device_id, refresh_token, output? } -> 201 response
  // Payload shape depends on ``output`` - callers choose what they want
  // to consume. Rtsp: { bridge_session_id, rtsp_path, has_audio }.
  // Hls:  { bridge_session_id, hls_path, has_audio }.
  app.post('/sessions', async (req, res) => {
    const { device_id: deviceId, refresh_token: refreshToken, output } = req.body || {};
    if (!deviceId || !refreshToken) {
      return res.status(400).json({ error: 'device_id and refresh_token are required' });
    }

    const target = output === 'hls' ? 'hls' : 'rtsp';

    // Device-busy check (at sidecar level; Python layer also enforces a
    // concurrency cap before calling us).
    for (const s of sessions.values()) {
      if (s.deviceId === deviceId && s.state === 'active') {
        return res.status(409).json({ error: 'device_busy' });
      }
    }

    const bridgeSessionId = randomUUID();
    let session;
    try {
      session = await factory.start({
        deviceId,
        refreshToken,
        bridgeSessionId,
        output: target,
      });
    } catch (err) {
      return res.status(502).json({ error: 'sip_failed', detail: String(err?.message || err) });
    }

    // Watchdog: if Ring terminates the SIP session, drop our entry and
    // stop the RTSP / HLS write within 5 s. session.onTerminated fires
    // from the SIP implementation; the fake used in tests fires it
    // immediately to exercise the watchdog path.
    session.onTerminated(() => {
      session.state = 'terminated';
      setTimeout(() => sessions.delete(bridgeSessionId), 5000).unref();
    });

    sessions.set(bridgeSessionId, session);

    if (target === 'hls') {
      return res.status(201).json({
        bridge_session_id: bridgeSessionId,
        hls_path: session.hlsPath,
        has_audio: session.hasAudio,
      });
    }
    return res.status(201).json({
      bridge_session_id: bridgeSessionId,
      rtsp_path: session.rtspPath,
      has_audio: session.hasAudio,
    });
  });

  // DELETE /sessions/{bridge_session_id} -> 204 (idempotent)
  app.delete('/sessions/:id', async (req, res) => {
    const { id } = req.params;
    const session = sessions.get(id);
    if (session) {
      try {
        await session.stop();
      } catch (err) {
        console.error(`sip session stop failed bridge_session_id=${id} error=${err?.message}`);
      }
      sessions.delete(id);
      // Also clean up the per-device HLS directory so the next session
      // starts with a fresh playlist.
      if (session.hlsPath) {
        const dir = path.join(hlsRoot, String(session.deviceId));
        try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* empty */ }
      }
    }
    return res.status(204).send();
  });

  // GET /sessions -> list
  app.get('/sessions', (_req, res) => {
    const payload = Array.from(sessions.entries()).map(([id, s]) => ({
      bridge_session_id: id,
      device_id: s.deviceId,
      state: s.state,
      started_at: s.startedAt,
      has_audio: s.hasAudio,
      hls_path: s.hlsPath || null,
      rtsp_path: s.rtspPath || null,
    }));
    res.json(payload);
  });

  // GET /health -> { status, active_sessions }
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', active_sessions: sessions.size });
  });

  // Expose the session map for tests that want to inspect it.
  app.locals.sessions = sessions;
  app.locals.hlsRoot = hlsRoot;
  return app;
}

// Start the HTTP server only when this module is invoked directly, not
// when imported by vitest.
if (import.meta.url === `file://${process.argv[1]}`) {
  const app = buildApp();
  app.listen(PORT, () => {
    console.log(
      `ring-sip-bridge listening on :${PORT} ` +
      `mediamtx=${MEDIAMTX_RTSP_URL} hls_root=${HLS_ROOT}`
    );
  });
}
