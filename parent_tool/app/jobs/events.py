from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
from dataclasses import dataclass
from threading import RLock
from typing import Any, AsyncIterator


@dataclass(frozen=True)
class JobEvent:
    event: str
    data: dict[str, Any]


@dataclass(frozen=True)
class _Subscriber:
    loop: asyncio.AbstractEventLoop
    queue: asyncio.Queue[JobEvent]


class EventBus:
    def __init__(self, *, queue_size: int = 32) -> None:
        if queue_size < 1:
            raise ValueError("queue_size must be positive")
        self.queue_size = queue_size
        self._subscribers: dict[str, list[_Subscriber]] = {}
        self._lock = RLock()

    @asynccontextmanager
    async def subscribe(self, job_id: str) -> AsyncIterator[asyncio.Queue[JobEvent]]:
        subscriber = _Subscriber(
            loop=asyncio.get_running_loop(),
            queue=asyncio.Queue(maxsize=self.queue_size),
        )
        with self._lock:
            self._subscribers.setdefault(job_id, []).append(subscriber)
        try:
            yield subscriber.queue
        finally:
            with self._lock:
                current = self._subscribers.get(job_id, [])
                if subscriber in current:
                    current.remove(subscriber)
                if not current:
                    self._subscribers.pop(job_id, None)

    def publish(self, event: JobEvent, *, job_id: str) -> None:
        with self._lock:
            subscribers = tuple(self._subscribers.get(job_id, ()))
        for subscriber in subscribers:
            try:
                subscriber.loop.call_soon_threadsafe(self._offer, subscriber.queue, event)
            except RuntimeError:
                continue

    @staticmethod
    def _offer(queue: asyncio.Queue[JobEvent], event: JobEvent) -> None:
        if queue.full():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
        queue.put_nowait(event)
