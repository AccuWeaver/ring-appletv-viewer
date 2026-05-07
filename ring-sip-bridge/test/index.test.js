/**
 * Vitest tests for the ring-sip-bridge HTTP control plane.
 *
 * Uses ``createTestSessionFactory`` injection to drive each scenario
 * without touching the network. Covers:
 *   - happy path: POST -> DELETE roundtrip
 *   - SIP failure: 502 sip_failed
 *   - device busy: 409 device_busy on a second concurrent start
 *   - audio-absent: has_audio=false propagated
 *   - watchdog: Ring-side termination drops the session within 5s
 */

import { describe, it, expect } from 'vitest';
import request from 'supertest';
import { buildApp } from '../index.js';
import { createTestSessionFactory } from '../session.js';

describe('POST /sessions', () => {
  it('starts a session and returns bridge_session_id + rtsp_path', async () => {
    const app = buildApp({ sessionFactory: createTestSessionFactory() });
    const res = await request(app)
      .post('/sessions')
      .send({ device_id: 'cam1', refresh_token: 'tok' });
    expect(res.status).toBe(201);
    expect(res.body.bridge_session_id).toMatch(/^[0-9a-f-]{36}$/);
    expect(res.body.rtsp_path).toBe('ring/cam1');
    expect(res.body.has_audio).toBe(true);
  });

  it('returns 502 sip_failed when SIP negotiation fails', async () => {
    const app = buildApp({
      sessionFactory: createTestSessionFactory({ startBehavior: 'fail' }),
    });
    const res = await request(app)
      .post('/sessions')
      .send({ device_id: 'cam1', refresh_token: 'tok' });
    expect(res.status).toBe(502);
    expect(res.body.error).toBe('sip_failed');
  });

  it('returns 409 device_busy when the device already has an active session', async () => {
    const app = buildApp({ sessionFactory: createTestSessionFactory() });
    const first = await request(app).post('/sessions').send({
      device_id: 'cam1',
      refresh_token: 'tok',
    });
    expect(first.status).toBe(201);

    const second = await request(app).post('/sessions').send({
      device_id: 'cam1',
      refresh_token: 'tok',
    });
    expect(second.status).toBe(409);
    expect(second.body.error).toBe('device_busy');
  });

  it('propagates has_audio=false when the session lacks audio', async () => {
    const app = buildApp({
      sessionFactory: createTestSessionFactory({ hasAudio: false }),
    });
    const res = await request(app)
      .post('/sessions')
      .send({ device_id: 'cam1', refresh_token: 'tok' });
    expect(res.status).toBe(201);
    expect(res.body.has_audio).toBe(false);
  });

  it('rejects missing device_id or refresh_token with 400', async () => {
    const app = buildApp({ sessionFactory: createTestSessionFactory() });
    const res = await request(app).post('/sessions').send({});
    expect(res.status).toBe(400);
  });
});

describe('DELETE /sessions/:id', () => {
  it('is idempotent for unknown ids', async () => {
    const app = buildApp({ sessionFactory: createTestSessionFactory() });
    const res = await request(app).delete('/sessions/00000000-0000-0000-0000-000000000000');
    expect(res.status).toBe(204);
  });

  it('tears down an active session', async () => {
    const app = buildApp({ sessionFactory: createTestSessionFactory() });
    const created = await request(app)
      .post('/sessions')
      .send({ device_id: 'cam1', refresh_token: 'tok' });
    const id = created.body.bridge_session_id;

    const deleted = await request(app).delete(`/sessions/${id}`);
    expect(deleted.status).toBe(204);

    const listing = await request(app).get('/sessions');
    expect(listing.body.map((s) => s.bridge_session_id)).not.toContain(id);
  });
});

describe('GET /health', () => {
  it('reports active_sessions count', async () => {
    const app = buildApp({ sessionFactory: createTestSessionFactory() });
    const initial = await request(app).get('/health');
    expect(initial.body).toEqual({ status: 'ok', active_sessions: 0 });

    await request(app)
      .post('/sessions')
      .send({ device_id: 'cam1', refresh_token: 'tok' });
    const after = await request(app).get('/health');
    expect(after.body.active_sessions).toBe(1);
  });
});

describe('watchdog', () => {
  it('marks a session terminated when Ring-initiated termination fires', async () => {
    const app = buildApp({
      sessionFactory: createTestSessionFactory({ terminationDelayMs: 10 }),
    });
    const res = await request(app)
      .post('/sessions')
      .send({ device_id: 'cam1', refresh_token: 'tok' });
    const id = res.body.bridge_session_id;

    // Wait for the synthetic termination to fire. The 5 s watchdog grace
    // period then drops the entry from the map; we don't want to block
    // the suite for 5 s, so we only assert that the session is marked
    // ``terminated`` once the termination callback has fired.
    await new Promise((r) => setTimeout(r, 100));
    const sessions = app.locals.sessions;
    const s = sessions.get(id);
    expect(s?.state).toBe('terminated');
  }, 10000);
});
