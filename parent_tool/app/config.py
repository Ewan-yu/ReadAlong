from __future__ import annotations

import os
from pathlib import Path
from typing import Literal
from uuid import uuid4

from platformdirs import user_data_path
from pydantic import BaseModel, ConfigDict, Field, ValidationError


def default_data_root() -> Path:
    return (user_data_path("ReadAlong") / "workspace").expanduser().resolve()


def default_settings_path() -> Path:
    return (user_data_path("ReadAlong") / "settings.json").expanduser().resolve()


class UserSettings(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: Literal[1] = 1
    data_root: Path | None = None
    pending_source_cleanup: Path | None = None


class UserSettingsStore:
    """Small, atomic configuration store kept outside the data root."""

    def __init__(self, path: Path) -> None:
        self.path = path.expanduser().resolve()

    def read(self) -> UserSettings:
        if not self.path.is_file():
            return UserSettings()
        try:
            return UserSettings.model_validate_json(self.path.read_text(encoding="utf-8"))
        except (OSError, ValidationError, ValueError):
            # A malformed optional setting must not make existing projects
            # inaccessible.  The user can set a new location again in Settings.
            return UserSettings()

    def write(self, value: UserSettings) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_name(f".{self.path.name}.{uuid4().hex}.tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as stream:
                stream.write(value.model_dump_json(exclude_none=True))
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            temporary.unlink(missing_ok=True)


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True)

    workspace_root: Path
    managed_by: Literal["environment", "user", "default"] = "default"
    settings_path: Path = Field(default_factory=default_settings_path)
    allow_pending_cleanup: bool = False

    @classmethod
    def from_environment(cls) -> "Settings":
        configured = os.environ.get("READALONG_WORKSPACE_ROOT")
        settings_path = default_settings_path()
        if configured:
            return cls(
                workspace_root=Path(configured).expanduser().resolve(),
                managed_by="environment",
                settings_path=settings_path,
                allow_pending_cleanup=True,
            )
        user = UserSettingsStore(settings_path).read()
        if user.data_root is not None:
            return cls(
                workspace_root=user.data_root.expanduser().resolve(),
                managed_by="user",
                settings_path=settings_path,
                allow_pending_cleanup=True,
            )
        return cls(
            workspace_root=default_data_root(),
            managed_by="default",
            settings_path=settings_path,
            allow_pending_cleanup=True,
        )
