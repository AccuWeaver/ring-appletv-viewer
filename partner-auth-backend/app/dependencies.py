"""FastAPI dependency hooks used by the /mock/* routes.

`get_ring_adapter` is a placeholder that raises `RuntimeError` until the
application startup code overrides it via `app.dependency_overrides`. This
pattern lets route handlers import the symbol at module-load time without
needing a real adapter instance, while still letting the factory install
exactly one instance per running application (see design doc, "Adapter
Factory and FastAPI DI").

`get_source_router` is a similar placeholder for the SourceRouter singleton
used by the /mock/* route handlers after the routing-layer refactor (task 13.1).
"""

from app.adapters.base import RingAdapter
from app.routing.source_router import SourceRouter


def get_ring_adapter() -> RingAdapter:
    """Return the active RingAdapter singleton.

    Overridden at startup by `app/main.py`. Raising here makes the
    misconfiguration visible immediately if the override is forgotten.
    """
    raise RuntimeError("RingAdapter dependency not wired; check app startup lifespan hook")


def get_source_router() -> SourceRouter:
    """Return the active SourceRouter singleton.

    Overridden at startup by `app/main.py`. Raising here makes the
    misconfiguration visible immediately if the override is forgotten.
    """
    raise RuntimeError("SourceRouter dependency not wired; check app startup lifespan hook")
