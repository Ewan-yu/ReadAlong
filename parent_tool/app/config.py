from __future__ import annotations

import os
from pathlib import Path

from platformdirs import user_data_path
from pydantic import BaseModel, ConfigDict


class Settings(BaseModel):
    model_config = ConfigDict(frozen=True)

    workspace_root: Path

    @classmethod
    def from_environment(cls) -> "Settings":
        configured = os.environ.get("READALONG_WORKSPACE_ROOT")
        root = Path(configured) if configured else user_data_path("ReadAlong") / "workspace"
        return cls(workspace_root=root.expanduser().resolve())
