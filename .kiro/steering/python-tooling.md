---
inclusion: fileMatch
fileMatchPattern: ['partner-auth-backend/**/*.py', 'partner-auth-backend/pyproject.toml']
---

# Python Tooling — partner-auth-backend

All Python code lives in `partner-auth-backend/`. Tooling is managed via `uv` and configured in `pyproject.toml`. Never bypass these tools or invoke them directly.

## Commands

| Task | Command (run from `partner-auth-backend/`) |
|---|---|
| Run all tests | `uv run pytest` |
| Run a single test file | `uv run pytest tests/test_foo.py` |
| Run a script | `uv run python <script>` |
| Add a dependency | `uv add <package>` |
| Add a dev dependency | `uv add --dev <package>` |
| Type-check | `uv run mypy app` |
| Lint | `uv run ruff check .` |
| Format | `uv run ruff format .` |
| Auto-fix lint | `uv run ruff check --fix .` |

**Never** use `python`, `pytest`, `mypy`, `pip install`, `black`, `flake8`, `pylint`, `autopep8`, or `isort` directly. Never reference `.venv` paths.

## Code Style

- Python target: **3.12** (`requires-python = ">=3.12,<3.14"`)
- Always add `from __future__ import annotations` at the top of every file for forward-reference compatibility
- Line length: 100 (soft — `E501` is ignored, so ruff won't enforce it)
- Active ruff rule sets: `E`, `F`, `W`, `I`, `N`, `UP`, `B`, `A`, `SIM`
- `app` is treated as a first-party import for isort ordering

## Project Stack

- **Framework**: FastAPI with Pydantic v2 models
- **Server**: Uvicorn
- **HTTP client**: `httpx` (async)
- **Database**: `aiosqlite` (async SQLite, file `tokens.db`)
- **Auth/crypto**: `cryptography`, `slowapi` (rate limiting)
- **Config**: `python-dotenv` + environment variables validated at startup via `app/config.py`; raises `ConfigurationError` on bad config, which causes a non-zero exit

## Architecture

```
app/
  adapters/     # RingAdapter base + implementations (mock, unofficial, partner)
  data/         # TokenStore, RefreshTokenStore, FernetEncryptor
  middleware/   # InputSanitizationMiddleware, rate limiter
  models/       # Pydantic request/response models
  routes/       # FastAPI routers (app_api, mock_ring_api, ring_callbacks)
  routing/      # SourceRouter, HealthManager, SnapshotCache, SnapshotRefreshJob
  services/     # TokenService, auth helpers
  config.py     # Settings via python-dotenv
  dependencies.py  # DI placeholder functions
  main.py       # App wiring, lifespan, middleware, exception handlers
```

### Key Patterns

- **Dependency injection**: Use `FastAPI.Depends()`. Singletons (`RingAdapter`, `SourceRouter`) are placeholder functions in `app/dependencies.py` that raise `RuntimeError` until overridden via `app.dependency_overrides` in the lifespan hook. Never instantiate these directly in route handlers.
- **Lifespan hook**: All startup/shutdown logic (adapter creation, DB init, background jobs) lives in the `@asynccontextmanager lifespan(app)` in `main.py`. Do not use `@app.on_event`.
- **Error handling**: Adapter errors use `RingAdapterError` with a stable `code` and `http_status`. The global handler maps these to `{"error": "<code>"}` — never expose tracebacks, file paths, or raw exception messages to callers.
- **Logging**: Structured key=value log lines (e.g., `request_id=%s method=%s path=%s`). A redacting filter (`app/logging_redaction.py`) is installed at startup — never log tokens, secrets, or PII.
- **Request IDs**: Every request gets a `uuid4` request ID attached to `request.state.request_id` and returned in the `X-Request-ID` response header.

## Testing

- Tests live in `partner-auth-backend/tests/`, mirroring the `app/` structure
- `asyncio_mode = "auto"` — async test functions work without `@pytest.mark.asyncio`
- **Session-scoped autouse fixture** `_install_mock_adapter` in `tests/conftest.py` installs a `MockRingAdapter` and `SourceRouter` into `app.dependency_overrides` for the whole test session. Most tests rely on this — do not remove it
- Use fakes/mocks from `tests/fakes/` rather than patching internals with `unittest.mock` where possible
- Integration tests live in `tests/integration/`
- Property-based tests use `hypothesis`: `@given` + `@settings` decorators, strategies from `hypothesis.strategies`
- When writing tests that need the lifespan (e.g., integration tests), wrap the client in `app.router.lifespan_context(app)` — the autouse fixture's `dependency_overrides` still win over the placeholder, so both patterns coexist safely
