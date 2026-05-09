Let me first explore how mediamtx is configured and what paths are available, since that determines whether live-stream-via-HLS is feasible:

## TASK 1: Run ring-adapter-live-media spec to completion
- **STATUS**: done
- **USER QUERIES**: "Run all tasks for this spec"
- **DETAILS**: Orchestrated execution of all 64 tasks in the `ring-adapter-live-media` spec via DAG-based task dispatcher. All tasks marked completed. Delivered:
  - `FailureClass` enum + fallback-eligible sets
  - `SourceResult` wrapper type
  - Extended `RingAdapterError` hierarchy with `failure_class`
  - Tagged union `StreamSessionMap` entries
  - `HealthManager` (binary up/down, lazy quarantine expiry)
  - `SnapshotCache` (LRU byte-bounded, fresh/stale TTL)
  - `SourceRouter` (core routing algorithm, real-data guard, structured logging)
  - `PartnerRingAdapter` with full WHEP/snapshot/clip failure-class mapping
  - Extended `UnofficialRingAdapter` with new failure classifications
  - `SnapshotRefreshJob` with skip-if-running semantics
  - Refactored `/mock/*` route handlers to use `SourceRouter` with `X-Ring-Source` / `X-Ring-Snapshot-Age` headers
  - Extended `/health/adapter` endpoint
  - Full app wiring in `app/main.py` lifespan (HealthManager, SnapshotCache, SourceRouter, SnapshotRefreshJob)
  - 16 property-based tests covering routing determinism, real-data guarantee, cache invariants, health state machine, quarantine lifecycle, session lifecycle, fallback observability, capacity enforcement
  - Integration tests (routing, snapshot refresh, Partner WHEP, backward compatibility)
  - 282 tests passing
- **FILEPATHS**: `partner-auth-backend/app/routing/*`, `partner-auth-backend/app/adapters/*`, `partner-auth-backend/app/routes/mock_ring_api.py`, `partner-auth-backend/app/main.py`, `partner-auth-backend/tests/**`

## TASK 2: Enforce uv/ruff tooling via steering file
- **STATUS**: done
- **USER QUERIES**: "can we fix this so that you are using uv and ruff always"
- **DETAILS**: Created `.kiro/steering/python-tooling.md` with `inclusion: fileMatch` scoped to `partner-auth-backend/**/*.py` and `pyproject.toml`. Document captures: uv-only execution (no direct python/pip/.venv), ruff-only linting (no black/flake8/pylint), Python 3.12 target, `from __future__ import annotations` requirement, architecture conventions (DI via FastAPI placeholders, lifespan hook pattern, structured logging, error envelope format), testing patterns (`_install_mock_adapter` autouse fixture).
- **FILEPATHS**: `.kiro/steering/python-tooling.md`

## TASK 3: Resume task execution after pause
- **STATUS**: done
- **USER QUERIES**: "ok resume the tasks"
- **DETAILS**: Resumed DAG-driven execution from where paused. Eventually completed all 64 tasks as part of TASK 1 completion.

## TASK 4: Refine python-tooling steering document
- **STATUS**: done
- **USER QUERIES**: "Analyze the python-tooling.md steering document and refine it such that it will better guide an AI assistant"
- **DETAILS**: Changed front matter from `inclusion: auto` (invalid) to `inclusion: fileMatch` scoped to `partner-auth-backend/**/*.py` and `pyproject.toml`. Consolidated commands into single table, added Python 3.12 version, `from __future__ import annotations` rule, expanded architecture patterns (DI placeholders, lifespan hook, error envelope, structured logging, request IDs), clarified testing (`_install_mock_adapter` autouse fixture, lifespan coexistence for integration tests).
- **FILEPATHS**: `.kiro/steering/python-tooling.md`

## TASK 5: Run app in tvOS simulator
- **STATUS**: done
- **USER QUERIES**: "help me run the updated code in the simulator", "did you launch it to the device?"
- **DETAILS**: Started `docker compose up -d --build` (backend healthy at `localhost:8000`, `adapter_mode: unofficial`). Built tvOS app with `xcodebuild` for Apple TV 4K simulator (UDID `910338FE-CF4E-4E32-ABD2-99FEEE9C6E53`), installed via `xcrun simctl install`, launched via `xcrun simctl launch com.ringappletv`. User's `.env` has `RING_ADAPTER=unofficial` with real refresh token. Dashboard shows real cameras; player showed Apple BipBop test pattern (separate issue addressed in TASK 6).
- **FILEPATHS**: `docker-compose.yml`, `.env`, `RingAppleTV/RingAppleTV.xcodeproj`

## TASK 6: Fix test pattern / Events tab issues
- **STATUS**: done
- **USER QUERIES**: "still showing the test pattern and not my Ring cameras", "there is nothing on the events tab, didn't we work through fixing WebRTC so it would work on the simulator?", "c" (confirming both fixes)
- **DETAILS**: Diagnosed two root causes:
  1. **Events tab**: `DefaultEventService.fetchEvents(for: nil)` returned `[]` when deviceId was nil, but `EventsView` always called `loadEvents()` with no deviceId.
  2. **Test pattern**: The tvOS simulator WebRTC fork was completed (TASK `webrtc-tvos-fork` spec already done), but `RTCMTLVideoView` doesn't render frames on simulator (Metal decoder limitation). `ServiceContainer` gates `streamSessionManager` on `!targetEnvironment(simulator)`. Fallback in `PlayerView.mockHLSPlayer` used hardcoded Apple BipBop URL.
  
  Implemented both fixes:
  - Injected `DeviceService` into `DefaultEventService`. When `deviceId == nil`, fetches all devices, then fetches events per-device concurrently, merges + sorts descending + caps at 50.
  - Added optional `eventService` and `mediaService` to `PlayerViewModel`. Added `resolveLatestClipURL(for:)` helper that fetches recent events and returns the first clip URL that resolves successfully (probes up to 5 most recent events to handle Ring Protect gaps).
  - Updated `PlayerView.mockHLSPlayer` to use `session.sessionURL` if not the placeholder, else fall back to BipBop.
  - Updated `ServiceContainer.makePlayerViewModel()` to inject the services.
  - Updated test suite (`EventServiceTests.swift`, `PlayerViewModelTests.swift`).
- **FILEPATHS**: `RingAppleTV/Sources/Services/Implementations/DefaultEventService.swift`, `RingAppleTV/Sources/ViewModels/PlayerViewModel.swift`, `RingAppleTV/Sources/Views/Player/PlayerView.swift`, `RingAppleTV/Sources/App/ServiceContainer.swift`, `RingAppleTV/Tests/Services/EventServiceTests.swift`, `RingAppleTV/Tests/ViewModels/PlayerViewModelTests.swift`

## TASK 7: Fix download_video 404 and Menu button
- **STATUS**: done
- **USER QUERIES**: "back to the test pattern video and the escape not working (closes the app). shouldn't I be seeing a real video now?"
- **DETAILS**: Backend logs showed `download_video` returning 404 for every event because the route handler `partner-auth-backend/app/routes/mock_ring_api.py` hardcoded `event_id=None` on line 91 — never read it from request body. The app was sending `{"event_id": eventId}` in body but it was ignored. Fixed by parsing JSON body for `event_id` field. Also improved `resolveLatestClipURL` to probe 5 events (Ring Protect issue: some events have recordings returning 302→S3 URL, some 404).
  
  Menu button closing the app: `.focusable(true)` and `.onExitCommand { dismiss() }` were attached to the inner `playerContent` which only renders in `.loaded` state. During `.idle`/`.loading` (initial player entry), no handler → Menu escaped NavigationView → quit app. Moved both modifiers to the outer `ZStack` in `PlayerView.swift` so they're always active regardless of state.
  
  Rebuilt backend (`docker compose up -d --build backend`) and app (xcodebuild + simctl install + launch). Build succeeded.
- **FILEPATHS**: `partner-auth-backend/app/routes/mock_ring_api.py`, `RingAppleTV/Sources/ViewModels/PlayerViewModel.swift`, `RingAppleTV/Sources/Views/Player/PlayerView.swift`

## TASK 8: Add "not live" banner and ideally stream real live video through mediamtx
- **STATUS**: in-progress
- **USER QUERIES**: "can we add a small banner on the upper right to indicate that the video is not live? Preferably the video should be the live stream so ideally we would translate that stream to make it work in the simulator. If we can do that we would still need to indicate it's going through the alternate path and not the partner API with Ring"
- **DETAILS**: Started investigating. Read `mediamtx.yml` — currently only has one path `test` for publisher-based RTSP/WHIP publish, and WHEP/WebRTC subscribe. Anonymous auth configured.
  
  Two parts required:
  1. **Banner on upper right** (straightforward) — needs to indicate video source/liveness. Should show different states:
     - "Not Live (Recording)" when falling back to event clip
     - "Not Live (Test Pattern)" when falling back to BipBop
     - "Live via SIP bridge" or similar when going through unofficial adapter path (ring-sip-bridge → mediamtx → HLS on simulator)
     - Nothing/hidden when using real Partner API WebRTC
  2. **Simulator-compatible live stream** (harder) — mediamtx supports HLS output from any published RTSP stream. The `ring-sip-bridge` sidecar already republishes Ring SIP/RTP as RTSP to `rtsp://mediamtx:8554/ring/{device_id}`. mediamtx can serve HLS on port 8888 from those paths by default. On simulator, instead of WebRTC/WHEP, the app could subscribe via HLS to `http://localhost:8888/ring/{device_id}/index.m3u8`. This would actually play real live video in the simulator.
  
  Conversation was cut off while reading mediamtx.yml. No code changes implemented yet for this task.
- **NEXT STEPS**:
  - Verify mediamtx's default HLS port (8888) is exposed in `docker-compose.yml`. Currently only 8554 (RTSP), 8889 (WHEP), 8189 (WebRTC ICE) are exposed. Add `8888:8888` if not.
  - Update mediamtx.yml to explicitly enable HLS and add a `ring/~$` regex path (or `all` to allow any path) so `ring-sip-bridge` can publish.
  - Verify `ring-sip-bridge` actually starts a SIP session when `create_stream_session` is called — it may lazily start on demand. Check if the tvOS app can trigger this before requesting the HLS URL, or if we need a new backend endpoint.
  - Add a new backend route or extend existing one: when request comes from simulator, return an HLS URL instead of WebRTC SDP. Options:
    - Extend `create_stream_session` to accept a `prefer_hls` flag, bypass WHEP, just start the SIP bridge, return HLS URL
    - Or: add new route like `POST /mock/devices/{id}/media/streaming/hls` that starts the bridge and returns HLS URL
  - On the app side, `ServiceContainer` currently sets `streamSessionManager = nil` on simulator. Add alternate simulator path: new `SimulatorLiveStreamService` that calls the backend, starts the SIP bridge via the existing create_stream_session (or new HLS endpoint), gets HLS URL, returns it via `StreamSession.sessionURL`. `PlayerView.mockHLSPlayer` already handles non-placeholder URLs.
  - Add `streamSource: StreamSource` enum to `StreamSession` model with cases: `liveWebRTC`, `liveHLSFallback`, `recordedEvent`, `testPattern`. Surface through `PlayerViewModel` to the view.
  - Add banner view in `PlayerView` — small pill/badge in top-right, conditionally visible based on `streamSource`. Use `ZStack(alignment: .topTrailing)` overlay inside `playerContent`. Text based on source: hide for `liveWebRTC`, show "Live (via bridge)" for `liveHLSFallback`, show "Recorded [timestamp]" for `recordedEvent`, show "Test Pattern" for `testPattern`.
  - Existing `.focusable(true)` + `.onExitCommand` on outer ZStack from TASK 7 should still work; ensure banner doesn't steal focus.
  - Update `PlayerViewModelTests.swift` with cases for each `streamSource` value.
- **FILEPATHS**:
  - `mediamtx.yml`
  - `docker-compose.yml`
  - `ring-sip-bridge/` (check what endpoints it exposes)
  - `partner-auth-backend/app/routes/mock_ring_api.py` (may need new HLS route)
  - `partner-auth-backend/app/adapters/unofficial.py` (already drives SIP bridge; may need refactor)
  - `RingAppleTV/Sources/Models/StreamSession.swift` (add `streamSource` enum)
  - `RingAppleTV/Sources/ViewModels/PlayerViewModel.swift` (set `streamSource` on session)
  - `RingAppleTV/Sources/Views/Player/PlayerView.swift` (add banner overlay)
  - `RingAppleTV/Sources/App/ServiceContainer.swift` (wire simulator-HLS path)

## TASK 9: Commit and push spec + changes
- **STATUS**: not-started
- **USER QUERIES**: "branch if needed, commit and push for this spec and our changes"
- **DETAILS**: User wants to commit all the work from TASK 1 (ring-adapter-live-media spec) plus the app-side changes from TASKS 6, 7, 8. Git status showed many modified files including backend, tests, and app sources. User said "branch if needed" — likely means create a new feature branch rather than pushing to main. Need to check current branch state, create a branch, stage and commit, push. Should follow git_safety guardrails from system prompt: push to new branch (never main), use `-u` to set upstream. User hasn't explicitly asked for a PR, but creating one via `gh pr create` would be consistent with repo patterns (see `.pr-bodies/` dir with pr2-6.md templates).
- **NEXT STEPS**:
  - Check current branch: `git branch --show-current` (was on `main` earlier per environment context)
  - Check git status for all modified/new files
  - Create feature branch, e.g. `git checkout -b feat/ring-adapter-live-media-and-sim-improvements`
  - Stage all changes: `git add -A` or stage selectively if needed
  - Review that no secrets/credentials are being committed (especially the `.env` which contains `RING_REFRESH_TOKEN`)
  - Check if `.env` is in `.gitignore` (should be — README says it is)
  - Commit with conventional commit message covering: ring-adapter-live-media spec implementation, events tab fix, player fallback improvements, menu button fix, python tooling steering file
  - Push with `-u` flag: `git push -u origin <branch-name>`
  - Optionally create PR using `gh pr create` (user didn't explicitly ask, but repo has PR body templates in `.pr-bodies/`)
  - **IMPORTANT**: TASK 8 (banner + live HLS) is in-progress and has NOT been implemented. User should be informed that commit will include TASK 1 spec + TASKS 6/7 fixes but NOT the banner/live-HLS work.
- **FILEPATHS**: Git-tracked files modified, list from `git status --short`

## USER CORRECTIONS AND INSTRUCTIONS

- **Python tooling**: Always use `uv run` prefix for Python execution. Never invoke `python`, `pytest`, `mypy`, or CLI tools directly. Never use `pip install` (use `uv add` or `uv pip install`). Never reference `.venv` paths directly. Never use `black`, `flake8`, `pylint`, `autopep8`, or `isort` — ruff handles all of them.
- **Code style**: Add `from __future__ import annotations` at top of every Python file. Python target is 3.12 (`>=3.12,<3.14`). Line length 100 (soft, E501 ignored).
- **Docker backend commands**: Run from `/Users/robw/Developer/ring-appletv-viewer/` root (not `partner-auth-backend/`). Rebuild backend with `docker compose up -d --build backend`.
- **tvOS simulator**: Apple TV 4K (3rd generation), UDID `910338FE-CF4E-4E32-ABD2-99FEEE9C6E53`. Build with `xcodebuild -project RingAppleTV.xcodeproj -scheme RingAppleTV -destination 'platform=tvOS Simulator,id=910338FE-CF4E-4E32-ABD2-99FEEE9C6E53' -configuration Debug build`. Install with `xcrun simctl install <UDID> <APP_PATH>`. App bundle id: `com.ringappletv`. Built app path: `/Users/robw/Library/Developer/Xcode/DerivedData/RingAppleTV-acgkvkyonqzgqlhczmlxirtzczmt/Build/Products/Debug-appletvsimulator/RingAppleTV.app`.
- **WebRTC on simulator**: The `webrtc-tvos-fork` spec was already done — the xcframework ships the `tvos-arm64-simulator` slice, WebRTC links in the simulator. However, `RTCMTLVideoView` does not render frames on simulator (Metal decoder limitation). `ServiceContainer` intentionally gates `streamSessionManager` on `!targetEnvironment(simulator)` for this reason.
- **Ring Protect**: User has Ring Protect for some events (they return 302→S3 signed URL) but not all (some return 404). Code should probe multiple events, not fail on the first 404.
- **Backend config**: User's `.env` has `RING_ADAPTER=unofficial` with real `RING_REFRESH_TOKEN`. Do not leak the token value in any output.
- **Git safety**: Push to new branches, never to `main`. Use `-u` flag to set upstream. Files like `.env` contain secrets and must not be committed.

## Files to read

- `/Users/robw/Developer/ring-appletv-viewer/mediamtx.yml` (last file being read when cut off)
- `/Users/robw/Developer/ring-appletv-viewer/docker-compose.yml` (need to check HLS port exposure)
- `/Users/robw/Developer/ring-appletv-viewer/ring-sip-bridge/` (check what endpoints the sidecar exposes)
- `/Users/robw/Developer/ring-appletv-viewer/RingAppleTV/Sources/Models/StreamSession.swift` (need to add streamSource enum)
- `/Users/robw/Developer/ring-appletv-viewer/RingAppleTV/Sources/Views/Player/PlayerView.swift` (banner overlay goes here)
- `/Users/robw/Developer/ring-appletv-viewer/RingAppleTV/Sources/ViewModels/PlayerViewModel.swift` (surface streamSource)
- `/Users/robw/Developer/ring-appletv-viewer/RingAppleTV/Sources/App/ServiceContainer.swift` (simulator-HLS wiring)
- `/Users/robw/Developer/ring-appletv-viewer/partner-auth-backend/app/routes/mock_ring_api.py` (may need HLS route)
- `/Users/robw/Developer/ring-appletv-viewer/.gitignore` (verify .env is ignored before committing)
- `/Users/robw/Developer/ring-appletv-viewer/.pr-bodies/pr6.md` (for PR body template reference)