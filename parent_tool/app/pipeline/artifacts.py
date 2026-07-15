from __future__ import annotations

import shutil
from pathlib import Path, PurePosixPath

from app.models.errors import PipelineError
from app.models.pipeline import OutputFile, PipelineState, StepId, StepSuccess
from app.pipeline.hashing import canonical_sha256, file_sha256
from app.pipeline.paths import WorkspacePaths, ensure_within


def _output_error(message: str, *, path: str | None = None) -> PipelineError:
    details = {"path": path} if path is not None else {}
    return PipelineError(
        "OUTPUT_VALIDATION_FAILED",
        message,
        details=details,
        status_code=500,
    )


class ArtifactStore:
    def __init__(self, paths: WorkspacePaths) -> None:
        self.paths = paths

    def create_staging(self, book_id: str, job_id: str) -> Path:
        staging = self.paths.staging(book_id, job_id)
        if staging.exists():
            raise _output_error("任务暂存目录已经存在。", path=str(staging))
        staging.mkdir(parents=True)
        return staging

    def build_manifest(
        self,
        staging: Path,
        outputs: tuple[str, ...],
    ) -> tuple[tuple[OutputFile, ...], str]:
        if not outputs:
            raise _output_error("处理步骤没有声明任何输出文件。")
        normalized: list[str] = []
        for value in outputs:
            normalized.append(self._normalize_output(value))
        if len(set(normalized)) != len(normalized):
            raise _output_error("处理步骤声明了重复输出文件。")

        manifest: list[OutputFile] = []
        staging_root = staging.resolve()
        for relative in sorted(normalized):
            candidate = ensure_within(staging_root, staging_root / Path(*PurePosixPath(relative).parts))
            self._reject_symlinks(staging_root, candidate)
            if not candidate.is_file():
                raise _output_error("声明的输出文件不存在。", path=relative)
            manifest.append(
                OutputFile(path=relative, size=candidate.stat().st_size, sha256=file_sha256(candidate))
            )
        frozen = tuple(manifest)
        fingerprint = canonical_sha256([item.model_dump(mode="json") for item in frozen])
        return frozen, fingerprint

    def publish(
        self,
        book_id: str,
        step_id: StepId,
        revision_id: str,
        staging: Path,
    ) -> str:
        expected_staging_root = self.paths.book(book_id) / ".runs"
        ensure_within(expected_staging_root, staging)
        if not staging.is_dir():
            raise _output_error("任务暂存目录不存在。", path=str(staging))
        target = self.paths.revision(book_id, step_id, revision_id)
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            raise _output_error("产物修订目录已经存在。", path=str(target))
        staging.rename(target)
        return target.relative_to(self.paths.book(book_id)).as_posix()

    def verify(self, book_id: str, step_id: StepId, success: StepSuccess) -> bool:
        try:
            expected = self.paths.revision(book_id, step_id, success.revision_id)
            actual = ensure_within(
                self.paths.book(book_id), self.paths.book(book_id) / Path(success.output_root)
            )
            if actual != expected or not actual.is_dir() or not success.outputs:
                return False
            for output in success.outputs:
                relative = self._normalize_output(output.path)
                candidate = ensure_within(actual, actual / Path(*PurePosixPath(relative).parts))
                self._reject_symlinks(actual, candidate)
                if not candidate.is_file() or candidate.stat().st_size != output.size:
                    return False
                if file_sha256(candidate) != output.sha256:
                    return False
            calculated = canonical_sha256(
                [item.model_dump(mode="json") for item in success.outputs]
            )
            return calculated == success.output_fingerprint
        except (OSError, PipelineError):
            return False

    def cleanup_staging(self, staging: Path) -> None:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)

    def discard_revision(self, book_id: str, output_root: str) -> None:
        candidate = ensure_within(
            self.paths.book(book_id), self.paths.book(book_id) / Path(output_root)
        )
        if candidate.exists():
            shutil.rmtree(candidate, ignore_errors=True)

    def cleanup_unreferenced(self, state: PipelineState) -> None:
        referenced = {
            success.output_root
            for step in state.steps.values()
            if (success := step.success) is not None
        }
        book_dir = self.paths.book(state.book_id)
        for step_id in StepId:
            revisions = self.paths.revisions(state.book_id, step_id)
            if not revisions.is_dir():
                continue
            for candidate in revisions.iterdir():
                relative = candidate.relative_to(book_dir).as_posix()
                if candidate.is_dir() and relative not in referenced:
                    shutil.rmtree(candidate, ignore_errors=True)

    @staticmethod
    def _normalize_output(value: str) -> str:
        if not value or "\\" in value:
            raise _output_error("输出路径必须是非空 POSIX 相对路径。", path=value)
        path = PurePosixPath(value)
        if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
            raise _output_error("输出路径不能逃逸暂存目录。", path=value)
        return path.as_posix()

    @staticmethod
    def _reject_symlinks(root: Path, candidate: Path) -> None:
        current = root
        for part in candidate.relative_to(root).parts:
            current = current / part
            if current.is_symlink():
                raise _output_error("输出路径不能包含符号链接。", path=str(candidate))
