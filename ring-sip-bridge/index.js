/**
 * ring-sip-bridge: HTTP control plane for Ring SIP session management.
 *
 * The Python backend calls us over HTTP to start, stop, and monitor Ring
 * SIP sessions. This file owns only the HTTP surface and session
 * bookkeeping; the real SIP negotiation lives in `./session.js` behind a
 * pluggable factory so `npm test` can drive the service with a fake
 * implementation that never touches the network.
 *
 * Requirements 6.1, 6.2, 6.5, 6.6, 6.8.
 */

import express from 'express';
import { randomUUID } from 'node:crypto';
import { createSessionFactory } from './session.js';

const PORT = Number(process.env.PORT || 3000);
const MEDIAMTX_RTSP_URL = process.env.MEDIAMTX_RTSP_URL || 'rtsp://mediamtx:8554/ring';

export function buildApp({ sessionFactory } = {}) {
  const factory = sessionFactory ?? createSessionFactory({ mediamtxRtspUrl: MEDIAMTX_RTSP_URL });
  const sessions = new Map(); // bridge_session_id -> RingCameraSession

  const app = express();
  app.use(express.json({ limit: '16kb' }));

  // POST /sessions { device_id, refresh_token } -> 201 { bridge_session_id, rtsp_path }
  app.post('/sessions', async (req, res) => {
    const { device_id: deviceId, refresh_token: refreshToken } = req.body || {};
    if (!deviceId || !refreshToken) {
      return res.status(400).json({ error: 'device_id and refresh_token are required' });
    }

    // Device-busy check (Req 6.7 at sidecar level; Python layer also
    // enforces a concurrency cap before calling us).
    for (const s of sessions.values()) {
      if (s.deviceId === deviceId && s.state === 'active') {
        return res.status(409).json({ error: 'device_busy' });
      }
    }

    const bridgeSessionId = randomUUID();
    let session;
    try {
      session = await factory.start({ deviceId, refreshToken, bridgeSessionId });
    } catch (err) {
      return res.status(502).json({ error: 'sip_failed', detail: String(err?.message || err) });
    }

    // Watchdog: if Ring terminates the SIP session, drop our entry and
    // stop the RTSP publish within 5 s (Req 6.6). session.onTerminated
    // fires from the SIP implementation; the fake implementation used in
    // tests fires it immediately to exercise the watchdog path.
    session.onTerminated(() => {
      session.state = 'terminated';
      // Keep the entry for a grace period so callers can observe state,
      // then drop it.
      setTimeout(() => sessions.delete(bridgeSessionId), 5000).unref();
    });

    sessions.set(bridgeSessionId, session);
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
        // Log and move on: idempotency demands success-on-teardown.
        console.error(`sip session stop failed bridge_session_id=${id} error=${err?.message}`);
      }
      sessions.delete(id);
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
    }));
    res.json(payload);
  });

  // GET /health -> { status, active_sessions }
  app.get('/health', (_req, res) => {
    res.json({ status: 'ok', active_sessions: sessions.size });
  });

  // Expose the session map for tests that want to inspect it.
  app.locals.sessions = sessions;
  return app;
}

// Start the HTTP server only when this module is invoked directly, not
// when imported by vitest.
if (import.meta.url === `file://${process.argv[1]}`) {
  const app = buildApp();
  app.listen(PORT, () => {
    console.log(`ring-sip-bridge listening on :${PORT} mediamtx=${MEDIAMTX_RTSP_URL}`);
  });
}
