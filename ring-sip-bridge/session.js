/**
 * Session factory for the ring-sip-bridge sidecar.
 *
 * The real implementation negotiates a Ring SIP session via
 * ``ring-client-api`` and spawns an RTP->RTSP republisher. It is
 * intentionally minimal scaffolding for now: the production SIP glue
 * requires live Ring credentials and is delivered as a separate, manual
 * integration step.
 *
 * Tests (`npm test`) can inject a custom factory into ``buildApp`` via
 * the ``sessionFactory`` option so the entire sidecar surface can be
 * exercised offline (Req 6.1, 6.5, 6.6, 6.8).
 */

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

export function createSessionFactory({ mediamtxRtspUrl }) {
  return {
    /**
     * Start a new SIP session for the given device. This scaffold is a
     * placeholder that records the arguments and returns a "session" with
     * a synthetic ``rtsp_path``. The real ring-client-api integration is
     * tracked separately.
     *
     * @param {{ deviceId: string, refreshToken: string, bridgeSessionId: string }} opts
     * @returns {Promise<RingCameraSession>}
     */
    async start({ deviceId, refreshToken, bridgeSessionId }) {
      // Intentionally ignore refreshToken after construction (Req 6.6 /
      // design note: "No secrets persisted to disk; refresh token only
      // held in-memory for the session duration"). We do NOT retain it
      // beyond this function.
      //
      // The production replacement would:
      //   const ringApi = new RingApi({ refreshToken });
      //   const camera = (await ringApi.getCameras())
      //       .find(c => String(c.id) === deviceId);
      //   const liveCall = await camera.streamLiveCall({
      //     output: `${mediamtxRtspUrl}/${deviceId}`,
      //   });
      //   liveCall.onCallEnded.subscribe(() => terminateCb?.());
      //
      // For now we return a non-network-hitting placeholder that the test
      // harness replaces via ``sessionFactory`` injection.
      void refreshToken;
      void bridgeSessionId;
      void mediamtxRtspUrl;

      const session = {
        deviceId,
        rtspPath: `ring/${deviceId}`,
        hasAudio: true,
        state: 'active',
        startedAt: Date.now(),
        _terminationListeners: [],
        async stop() {
          this.state = 'terminated';
        },
        onTerminated(cb) {
          this._terminationListeners.push(cb);
        },
      };
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
