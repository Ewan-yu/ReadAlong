from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, status

from app.api.dependencies import get_workspace_catalog_service, get_workspace_migration_service
from app.models.capabilities import CapabilitiesResponse
from app.models.workspace_catalog import StorageInfo, StorageMigrationRequest, StorageMigrationStatus
from app.services.capability_service import CapabilityService
from app.services.workspace_catalog_service import WorkspaceCatalogService
from app.services.workspace_migration_service import WorkspaceMigrationService


router = APIRouter(prefix="/api", tags=["system"])


@router.get("/capabilities", response_model=CapabilitiesResponse)
def get_capabilities() -> CapabilitiesResponse:
    return CapabilitiesResponse(capabilities=CapabilityService().inspect())


@router.get("/storage", response_model=StorageInfo)
def get_storage(
    catalog: Annotated[WorkspaceCatalogService, Depends(get_workspace_catalog_service)],
) -> StorageInfo:
    return catalog.storage()


@router.post("/storage/recalculate", response_model=StorageInfo)
def recalculate_storage(
    catalog: Annotated[WorkspaceCatalogService, Depends(get_workspace_catalog_service)],
) -> StorageInfo:
    # Size calculation is intentionally live in this first implementation;
    # retaining the endpoint gives the UI a stable refresh contract.
    return catalog.storage()


@router.post(
    "/storage/migrations",
    response_model=StorageMigrationStatus,
    status_code=status.HTTP_202_ACCEPTED,
)
def start_storage_migration(
    request: StorageMigrationRequest,
    migrations: Annotated[WorkspaceMigrationService, Depends(get_workspace_migration_service)],
) -> StorageMigrationStatus:
    return migrations.start(request.target_root)


@router.get("/storage/migrations/{migration_id}", response_model=StorageMigrationStatus)
def get_storage_migration(
    migration_id: str,
    migrations: Annotated[WorkspaceMigrationService, Depends(get_workspace_migration_service)],
) -> StorageMigrationStatus:
    return migrations.get(migration_id)
