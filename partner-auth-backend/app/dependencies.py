"""FastAPI dependency hooks used by the /mock/* routes.

`get_ring_adapter` is a placeholder that raises `RuntimeError` until the
application startup code overrides it via `app.dependency_overrides`. This
pattern lets route handlers import the symbol at module-load time without
needing a real adapter instance, while still letting the factory install
exactly one instance per running application (see design doc, "Adapter
Factory and FastAPI DI").
"""

from app.adapters.base import RingAdapter


def get_ring_adapter() -> RingAdapter:
    """Return the active RingAdapter singleton.

    Overridden at startup by `app/main.py`. Raising here makes the
    misconfiguration visible immediately if the override is forgotten.
    """
    raise RuntimeError(
        "RingAdapter dependency not wired; check app startup lifespan hook"
    )
