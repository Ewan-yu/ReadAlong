from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from threading import Event
from typing import Callable, Protocol

from pydantic import BaseModel

from app.models.errors import PipelineError
from app.models.pipeline import StepId, StepResult


STEP_DEPENDENCIES: dict[StepId, tuple[StepId, ...]] = {
    StepId.PAGES: (),
    StepId.OCR: (StepId.PAGES,),
    StepId.PROOFREAD: (StepId.OCR,),
    StepId.AUDIO: (StepId.PROOFREAD,),
    StepId.EXPORT: (StepId.AUDIO,),
}


def transitive_successors(step_id: StepId) -> tuple[StepId, ...]:
    successors: list[StepId] = []
    frontier = [step_id]
    while frontier:
        current = frontier.pop(0)
        direct = [candidate for candidate, deps in STEP_DEPENDENCIES.items() if current in deps]
        for candidate in direct:
            if candidate not in successors:
                successors.append(candidate)
                frontier.append(candidate)
    return tuple(successors)


class CancellationToken:
    def __init__(self) -> None:
        self._requested = Event()

    @property
    def requested(self) -> bool:
        return self._requested.is_set()

    def request(self) -> None:
        self._requested.set()

    def raise_if_cancelled(self) -> None:
        if self.requested:
            raise PipelineError("JOB_CANCELLED", "任务已取消。", status_code=409)


ProgressReporter = Callable[[float, str], None]


@dataclass(frozen=True)
class StepRunContext:
    book_id: str
    workspace_dir: Path
    staging_dir: Path
    source_pdf_sha256: str | None
    dependency_outputs: dict[StepId, Path]
    progress: ProgressReporter
    cancellation: CancellationToken


class PipelineStep(Protocol):
    step_id: StepId
    implementation_version: str
    params_model: type[BaseModel]

    def run(self, context: StepRunContext, params: BaseModel) -> StepResult: ...


class StepRegistry:
    def __init__(self, steps: tuple[PipelineStep, ...] = ()) -> None:
        self._steps = {step.step_id: step for step in steps}

    def get(self, step_id: StepId) -> PipelineStep:
        try:
            return self._steps[step_id]
        except KeyError as exc:
            raise PipelineError(
                "STEP_NOT_FOUND",
                "该处理步骤尚未安装。",
                details={"step_id": step_id.value},
                status_code=404,
            ) from exc
