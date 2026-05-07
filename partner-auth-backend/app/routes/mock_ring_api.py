"""Ring adapter-backed routes (formerly the hardcoded mock).

The URL prefix ``/mock`` is preserved so the tvOS app does not change. All
business logic has moved into ``RingAdapter`` implementations under
``app/adapters/``; the handlers here only extract URL parameters and wrap
the adapter return values in FastAPI response classes.
"""

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response

from app.adapters.base import RingAdapter
from app.dependencies import get_ring_adapter

router = APIRouter(prefix="/mock")


@router.get("/devices")
async def get_devices(
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
) -> JSONResponse:
    return JSONResponse(status_code=200, content=await adapter.list_devices())


@router.get("/history/devices/{device_id}/events")
async def get_events(
    device_id: str,
    limit: int = 10,
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
) -> JSONResponse:
    events = await adapter.list_events(device_id, limit)
    return JSONResponse(status_code=200, content=events)


@router.post("/devices/{device_id}/media/image/download")
async def download_snapshot(
    device_id: str,
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
) -> Response:
    payload = await adapter.download_snapshot(device_id)
    return Response(content=payload.content, media_type=payload.content_type)


@router.post("/devices/{device_id}/media/video/download")
async def download_video(
    device_id: str,
    request: Request,
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
) -> JSONResponse:
    # Legacy handler didn't require an event_id; mock adapter accepts None.
    return JSONResponse(
        status_code=200,
        content=await adapter.download_video(device_id, event_id=None),
    )


@router.post("/devices/{device_id}/media/streaming/whep/sessions")
async def create_whep_session(
    device_id: str,
    request: Request,
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
) -> Response:
    sdp_offer = (await request.body()).decode()
    result = await adapter.create_stream_session(device_id, sdp_offer)
    return Response(
        content=result.sdp_answer,
        status_code=201,
        media_type="application/sdp",
        headers={"Location": result.location},
    )


@router.delete("/session/{session_id}")
async def delete_session(
    session_id: str,
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
) -> JSONResponse:
    await adapter.delete_stream_session(session_id)
    return JSONResponse(status_code=200, content={"status": "deleted"})
