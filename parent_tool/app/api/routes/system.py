from __future__ import annotations

from fastapi import APIRouter

from app.models.capabilities import CapabilitiesResponse
from app.services.capability_service import CapabilityService


router = APIRouter(prefix="/api", tags=["system"])


@router.get("/capabilities", response_model=CapabilitiesResponse)
def get_capabilities() -> CapabilitiesResponse:
    return CapabilitiesResponse(capabilities=CapabilityService().inspect())
