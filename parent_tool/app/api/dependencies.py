from __future__ import annotations

from fastapi import Request

from app.jobs.events import EventBus
from app.jobs.manager import JobManager
from app.pipeline.state_repository import StateRepository


def get_job_manager(request: Request) -> JobManager:
    return request.app.state.job_manager


def get_state_repository(request: Request) -> StateRepository:
    return request.app.state.state_repository


def get_event_bus(request: Request) -> EventBus:
    return request.app.state.event_bus
