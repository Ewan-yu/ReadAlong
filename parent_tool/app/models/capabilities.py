from __future__ import annotations

from enum import Enum

from pydantic import Field

from app.models.pipeline import FrozenModel


class CapabilityGroup(str, Enum):
    LOCAL = "local"
    CLOUD = "cloud"


class CapabilityStatus(FrozenModel):
    id: str
    name: str
    group: CapabilityGroup
    available: bool
    detail: str


class CapabilitiesResponse(FrozenModel):
    capabilities: tuple[CapabilityStatus, ...] = Field(min_length=1)
