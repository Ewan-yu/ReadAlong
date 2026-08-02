from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from pydantic import BaseModel, ConfigDict, Field


class PipelineError(Exception):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        details: dict[str, Any] | None = None,
        status_code: int = 400,
    ) -> None:
        super().__init__(f"{code}: {message}")
        self.code = code
        self.message = message
        self.details = details or {}
        self.status_code = status_code


_PRIVATE_DETAIL_KEYS = frozenset({
    'path',
    'cache',
    'ffmpeg_error',
    'ffprobe_error',
})


def public_error_details(details: Mapping[str, Any]) -> dict[str, Any]:
    """Remove local filesystem and subprocess diagnostics from API payloads."""

    def sanitize(value: Any) -> Any:
        if isinstance(value, Mapping):
            return {
                key: sanitize(item)
                for key, item in value.items()
                if key not in _PRIVATE_DETAIL_KEYS
            }
        if isinstance(value, list):
            return [sanitize(item) for item in value]
        if isinstance(value, tuple):
            return [sanitize(item) for item in value]
        return value

    return sanitize(details)


class ApiErrorResponse(BaseModel):
    model_config = ConfigDict(frozen=True)

    code: str
    message: str
    details: dict[str, Any] = Field(default_factory=dict)
    request_id: str
