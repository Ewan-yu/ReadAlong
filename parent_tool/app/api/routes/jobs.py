from __future__ import annotations

import json
from typing import Annotated, AsyncIterator

from fastapi import APIRouter, Depends
from sse_starlette import EventSourceResponse

from app.api.dependencies import get_event_bus, get_job_manager
from app.jobs.events import EventBus
from app.jobs.manager import JobManager
from app.models.errors import ApiErrorResponse
from app.models.jobs import JobSnapshot


router = APIRouter(prefix="/api/jobs", tags=["jobs"])
ERROR_RESPONSES = {
    404: {"model": ApiErrorResponse},
    409: {"model": ApiErrorResponse},
    500: {"model": ApiErrorResponse},
}


@router.get("/{job_id}", response_model=JobSnapshot, responses=ERROR_RESPONSES)
def get_job(
    job_id: str,
    manager: Annotated[JobManager, Depends(get_job_manager)],
) -> JobSnapshot:
    return manager.get(job_id)


@router.post("/{job_id}/cancel", response_model=JobSnapshot, responses=ERROR_RESPONSES)
def cancel_job(
    job_id: str,
    manager: Annotated[JobManager, Depends(get_job_manager)],
) -> JobSnapshot:
    return manager.cancel(job_id)


@router.get(
    "/{job_id}/events",
    response_class=EventSourceResponse,
    responses={
        200: {"content": {"text/event-stream": {}}},
        **ERROR_RESPONSES,
    },
)
async def job_events(
    job_id: str,
    manager: Annotated[JobManager, Depends(get_job_manager)],
    events: Annotated[EventBus, Depends(get_event_bus)],
) -> EventSourceResponse:
    manager.get(job_id)

    async def stream() -> AsyncIterator[dict[str, str]]:
        async with events.subscribe(job_id) as queue:
            snapshot = manager.get(job_id)
            yield {
                "event": "snapshot",
                "data": json.dumps(
                    snapshot.model_dump(mode="json"),
                    ensure_ascii=False,
                    separators=(",", ":"),
                ),
            }
            if snapshot.status.terminal:
                return
            while True:
                event = await queue.get()
                yield {
                    "event": event.event,
                    "data": json.dumps(
                        event.data, ensure_ascii=False, separators=(",", ":")
                    ),
                }
                if event.event in {"succeeded", "failed", "cancelled", "interrupted"}:
                    return

    return EventSourceResponse(stream(), ping=15)
