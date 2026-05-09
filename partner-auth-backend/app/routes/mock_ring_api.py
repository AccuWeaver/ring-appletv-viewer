"""Ring adapter-backed routes (formerly the hardcoded mock).

The URL prefix ``/mock`` is preserved so the tvOS app does not change. All
business logic has moved into ``RingAdapter`` implementations under
``app/adapters/``; the handlers here only extract URL parameters and wrap
the adapter return values in FastAPI response classes.

Route handlers now depend on ``SourceRouter`` rather than a single
``RingAdapter``. Every response carries an ``X-Ring-Source`` header whose
value is the Adapter_Mode that produced the payload (Requirements 1.8,
12.1–12.6). When the router serves a stale snapshot from the cache, the
response also carries ``X-Ring-Snapshot-Age`` (Requirements 6.9, 6.10).
"""

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, Response

from app.dependencies import get_source_router
from app.routing.source_router import SourceRouter

router = APIRouter(prefix="/mock")


def _source_headers(source_mode: str, cache_age_seconds: int | None) -> dict[str, str]:
    """Build the routing-metadata response headers.

    Always includes ``X-Ring-Source``. Adds ``X-Ring-Snapshot-Age`` only
    when *cache_age_seconds* is set (stale-serve path).

    Requirements: 1.8, 6.9, 6.10
    """
    headers: dict[str, str] = {"X-Ring-Source": source_mode}
    if cache_age_seconds is not None:
        headers["X-Ring-Snapshot-Age"] = str(cache_age_seconds)
    return headers


@router.get("/devices")
async def get_devices(
    router: SourceRouter = Depends(get_source_router),  # noqa: B008
) -> JSONResponse:
    result = await router.list_devices()
    if result.error is not None:
        raise result.error
    return JSONResponse(
        status_code=200,
        content=result.payload,
        headers=_source_headers(result.source_mode, result.cache_age_seconds),
    )


@router.get("/history/devices/{device_id}/events")
async def get_events(
    device_id: str,
    limit: int = 10,
    router: SourceRouter = Depends(get_source_router),  # noqa: B008
) -> JSONResponse:
    result = await router.list_events(device_id, limit)
    if result.error is not None:
        raise result.error
    return JSONResponse(
        status_code=200,
        content=result.payload,
        headers=_source_headers(result.source_mode, result.cache_age_seconds),
    )


@router.post("/devices/{device_id}/media/image/download")
async def download_snapshot(
    device_id: str,
    router: SourceRouter = Depends(get_source_router),  # noqa: B008
) -> Response:
    result = await router.download_snapshot(device_id)
    if result.error is not None:
        raise result.error
    payload = result.payload
    return Response(
        content=payload.content,
        media_type=payload.content_type,
        headers=_source_headers(result.source_mode, result.cache_age_seconds),
    )


@router.post("/devices/{device_id}/media/video/download")
async def download_video(
    device_id: str,
    request: Request,
    router: SourceRouter = Depends(get_source_router),  # noqa: B008
) -> JSONResponse:
    # Parse optional event_id from JSON body (the Unofficial adapter requires
    # one; the Mock adapter tolerates None and returns a canned URL).
    event_id: str | None = None
    try:
        body = await request.json()
        if isinstance(body, dict):
            raw = body.get("event_id")
            if isinstance(raw, str) and raw:
                event_id = raw
    except Exception:
        # Empty or non-JSON body — preserve legacy behaviour (event_id=None).
        event_id = None

    result = await router.download_video(device_id, event_id=event_id)
    if result.error is not None:
        raise result.error
    return JSONResponse(
        status_code=200,
        content=result.payload,
        headers=_source_headers(result.source_mode, result.cache_age_seconds),
    )


@router.post("/devices/{device_id}/media/streaming/whep/sessions")
async def create_whep_session(
    device_id: str,
    request: Request,
    router: SourceRouter = Depends(get_source_router),  # noqa: B008
) -> Response:
    sdp_offer = (await request.body()).decode()
    result = await router.create_stream_session(device_id, sdp_offer)
    if result.error is not None:
        raise result.error
    stream_result = result.payload
    extra_headers = _source_headers(result.source_mode, result.cache_age_seconds)
    extra_headers["Location"] = stream_result.location
    return Response(
        content=stream_result.sdp_answer,
        status_code=201,
        media_type="application/sdp",
        headers=extra_headers,
    )


@router.post("/devices/{device_id}/media/streaming/hls/sessions")
async def create_hls_session(
    device_id: str,
    router: SourceRouter = Depends(get_source_router),  # noqa: B008
) -> JSONResponse:
    """Start a live HLS stream by republishing Ring SIP/RTP through mediamtx.

    Used by clients that can't play WebRTC (currently the tvOS simulator).
    Returns the playable ``index.m3u8`` URL plus the session id callers use
    to tear the session down via ``DELETE /mock/session/{session_id}``.
    """
    result = await router.create_hls_stream_session(device_id)
    if result.error is not None:
        raise result.error
    hls_result = result.payload
    return JSONResponse(
        status_code=201,
        content={
            "session_id": hls_result.session_id,
            "hls_url": hls_result.hls_url,
        },
        headers=_source_headers(result.source_mode, result.cache_age_seconds),
    )


@router.delete("/session/{session_id}")
async def delete_session(
    session_id: str,
    router: SourceRouter = Depends(get_source_router),  # noqa: B008
) -> JSONResponse:
    result = await router.delete_stream_session(session_id)
    if result.error is not None:
        raise result.error
    return JSONResponse(
        status_code=200,
        content={"status": "deleted"},
        headers=_source_headers(result.source_mode, result.cache_age_seconds),
    )
