from __future__ import annotations

import hashlib
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from threading import Lock, Thread
from uuid import uuid4

from app.config import Settings, UserSettingsStore
from app.jobs.manager import JobManager
from app.models.errors import PipelineError
from app.models.pipeline import PipelineErrorInfo
from app.models.workspace_catalog import StorageMigrationPhase, StorageMigrationStatus
from app.pipeline.paths import WorkspacePaths


_COPY_CHUNK_BYTES = 1024 * 1024
_SAFETY_MARGIN = 1.10


@dataclass(frozen=True)
class _ManifestEntry:
    source: Path
    relative: Path
    size: int
    sha256: str


class WorkspaceMigrationService:
    """Copy a data root safely and make it active on the next application start."""

    def __init__(
        self,
        paths: WorkspacePaths,
        jobs: JobManager,
        settings: Settings,
        settings_store: UserSettingsStore,
    ) -> None:
        self.paths = paths
        self.jobs = jobs
        self.settings = settings
        self.settings_store = settings_store
        self._lock = Lock()
        self._active_context = None
        self._status: StorageMigrationStatus | None = None

    def get(self, migration_id: str) -> StorageMigrationStatus:
        with self._lock:
            if self._status is None or self._status.migration_id != migration_id:
                raise PipelineError("MIGRATION_NOT_FOUND", "没有找到该存储迁移任务。", status_code=404)
            return self._status

    def start(self, target_root: str) -> StorageMigrationStatus:
        if self.settings.managed_by == "environment":
            raise PipelineError(
                "STORAGE_MANAGED_BY_ENVIRONMENT",
                "当前数据目录由 READALONG_WORKSPACE_ROOT 管理，不能在界面中修改。",
                status_code=409,
            )
        target = self._validate_target(target_root)
        with self._lock:
            if self._active_context is not None:
                raise PipelineError("MIGRATION_ALREADY_RUNNING", "已有存储迁移正在进行。", status_code=409)
            context = self.jobs.maintenance("迁移数据目录")
            context.__enter__()
            migration_id = str(uuid4())
            self._active_context = context
            self._status = StorageMigrationStatus(
                migration_id=migration_id,
                target_root=str(target),
                phase=StorageMigrationPhase.QUEUED,
                progress=0,
                message="迁移任务已开始，正在检查目标目录。",
            )
            thread = Thread(
                target=self._run,
                args=(migration_id, target, context),
                name="readalong-storage-migration",
                daemon=True,
            )
            try:
                thread.start()
            except Exception:
                self._active_context = None
                context.__exit__(None, None, None)
                raise
            return self._status

    def _run(self, migration_id: str, target: Path, context: object) -> None:
        temporary: Path | None = None
        try:
            self._set(migration_id, phase=StorageMigrationPhase.PREFLIGHT, progress=0.02, message="正在检查磁盘空间。")
            entries = self._manifest()
            total = sum(entry.size for entry in entries)
            self._check_capacity(target, total)
            temporary = target.with_name(f".{target.name}.migration-{uuid4().hex}")
            if temporary.exists():
                raise PipelineError("MIGRATION_TARGET_INVALID", "迁移临时目录已存在，请重新选择位置。", status_code=409)
            temporary.mkdir(parents=True)
            self._set(migration_id, phase=StorageMigrationPhase.COPYING, progress=0.04, message="正在复制项目数据。", total_bytes=total)
            copied = self._copy(entries, temporary, total, migration_id)
            self._set(migration_id, phase=StorageMigrationPhase.VERIFYING, progress=0.93, message="正在逐文件校验复制结果。", copied_bytes=copied, total_bytes=total)
            self._verify(entries, temporary, total, migration_id)
            (temporary / "voices").mkdir(exist_ok=True)
            (temporary / "workspaces").mkdir(exist_ok=True)
            (temporary / ".engine").mkdir(exist_ok=True)
            if target.exists():
                target.rmdir()
            temporary.rename(target)
            current = self.settings_store.read()
            self.settings_store.write(
                current.model_copy(update={"data_root": target, "pending_source_cleanup": self.paths.root})
            )
            self._set(migration_id, phase=StorageMigrationPhase.SWITCHED, progress=1, message="复制和校验完成。请重启家长端以切换到新目录。", copied_bytes=copied, total_bytes=total, restart_required=True)
            temporary = None
        except Exception as exc:
            if temporary is not None and temporary.exists():
                shutil.rmtree(temporary, ignore_errors=True)
            error = self._to_error(exc)
            self._set(migration_id, phase=StorageMigrationPhase.FAILED, progress=0, message=error.message, error=error)
        finally:
            with self._lock:
                self._active_context = None
            context.__exit__(None, None, None)  # type: ignore[attr-defined]

    def _manifest(self) -> tuple[_ManifestEntry, ...]:
        source_root = self.paths.root
        entries: list[_ManifestEntry] = []
        for book_id in self._book_ids():
            book = self.paths.book(book_id)
            entries.extend(self._walk_files(book, Path("workspaces") / book_id))
        for name in (".engine", ".trash", "voices"):
            directory = source_root / name
            if directory.is_dir():
                entries.extend(self._walk_files(directory, Path(name), skip_instance_lock=name == ".engine"))
        return tuple(entries)

    def _book_ids(self) -> tuple[str, ...]:
        root = self.paths.workspace_root
        if not root.is_dir():
            return ()
        books: list[str] = []
        for candidate in root.iterdir():
            if candidate.is_dir() and (candidate / "state.json").is_file():
                if self.paths.book(candidate.name) == candidate.resolve():
                    books.append(candidate.name)
        return tuple(sorted(books))

    def _walk_files(self, source: Path, relative_root: Path, *, skip_instance_lock: bool = False) -> list[_ManifestEntry]:
        if self._is_reparse(source):
            raise PipelineError("MIGRATION_SOURCE_UNSAFE", "数据目录包含无法安全迁移的链接目录。", details={"path": str(source)}, status_code=409)
        entries: list[_ManifestEntry] = []
        for directory, names, filenames in os.walk(source, followlinks=False):
            current = Path(directory)
            for name in names:
                linked_directory = current / name
                if self._is_reparse(linked_directory):
                    raise PipelineError(
                        "MIGRATION_SOURCE_UNSAFE",
                        "数据目录包含无法安全迁移的链接目录。",
                        details={"path": str(linked_directory)},
                        status_code=409,
                    )
            for filename in filenames:
                file = current / filename
                if self._is_reparse(file):
                    raise PipelineError("MIGRATION_SOURCE_UNSAFE", "数据目录包含无法安全迁移的链接文件。", details={"path": str(file)}, status_code=409)
                relative = relative_root / file.relative_to(source)
                if skip_instance_lock and relative.as_posix() == ".engine/instance.lock":
                    continue
                size, digest = self._file_digest(file)
                entries.append(_ManifestEntry(file, relative, size, digest))
        return entries

    def _copy(self, entries: tuple[_ManifestEntry, ...], temporary: Path, total: int, migration_id: str) -> int:
        copied = 0
        for entry in entries:
            destination = temporary / entry.relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            with entry.source.open("rb") as source, destination.open("xb") as output:
                while chunk := source.read(_COPY_CHUNK_BYTES):
                    output.write(chunk)
                    copied += len(chunk)
                output.flush()
                os.fsync(output.fileno())
            progress = 0.04 + (0.88 * copied / total if total else 0.88)
            self._set(migration_id, phase=StorageMigrationPhase.COPYING, progress=progress, message=f"正在复制项目数据（{copied} / {total} 字节）。", copied_bytes=copied, total_bytes=total)
        return copied

    def _verify(self, entries: tuple[_ManifestEntry, ...], temporary: Path, total: int, migration_id: str) -> None:
        verified = 0
        for entry in entries:
            candidate = temporary / entry.relative
            size, digest = self._file_digest(candidate)
            if size != entry.size or digest != entry.sha256:
                raise PipelineError("MIGRATION_VERIFICATION_FAILED", "复制后的文件校验失败，原目录未被修改。", details={"path": entry.relative.as_posix()}, status_code=500)
            verified += size
            progress = 0.93 + (0.07 * verified / total if total else 0.07)
            self._set(migration_id, phase=StorageMigrationPhase.VERIFYING, progress=progress, message="正在逐文件校验复制结果。", copied_bytes=verified, total_bytes=total)

    def _validate_target(self, raw: str) -> Path:
        candidate = Path(raw).expanduser()
        if not candidate.is_absolute():
            raise PipelineError("MIGRATION_TARGET_INVALID", "请选择绝对本地目录，例如 D:\\ReadAlongData。", status_code=422)
        target = candidate.resolve(strict=False)
        source = self.paths.root.resolve()
        if target == source or target.is_relative_to(source) or source.is_relative_to(target):
            raise PipelineError("MIGRATION_TARGET_INVALID", "新目录不能是当前数据目录或它的父子目录。", status_code=422)
        if target.exists() and (not target.is_dir() or any(target.iterdir())):
            raise PipelineError("MIGRATION_TARGET_NOT_EMPTY", "请选择不存在或空的目标目录，避免覆盖已有文件。", status_code=409)
        return target

    @staticmethod
    def _check_capacity(target: Path, total: int) -> None:
        probe = target if target.exists() else target.parent
        while not probe.exists():
            probe = probe.parent
        try:
            free = shutil.disk_usage(probe).free
        except OSError as exc:
            raise PipelineError("MIGRATION_TARGET_UNAVAILABLE", "无法读取目标磁盘空间。", status_code=422) from exc
        required = int(total * _SAFETY_MARGIN)
        if free < required:
            raise PipelineError("MIGRATION_INSUFFICIENT_SPACE", "目标磁盘可用空间不足，需要源数据大小外加 10% 余量。", details={"required_bytes": required, "free_bytes": free}, status_code=409)

    def _set(self, migration_id: str, **updates: object) -> None:
        with self._lock:
            if self._status is not None and self._status.migration_id == migration_id:
                self._status = self._status.model_copy(update=updates)

    @staticmethod
    def _file_digest(path: Path) -> tuple[int, str]:
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as stream:
            while chunk := stream.read(_COPY_CHUNK_BYTES):
                size += len(chunk)
                digest.update(chunk)
        return size, digest.hexdigest()

    @staticmethod
    def _is_reparse(path: Path) -> bool:
        try:
            attributes = path.lstat().st_file_attributes
            return path.is_symlink() or bool(attributes & 0x400)
        except AttributeError:
            return path.is_symlink()
        except OSError:
            return True

    @staticmethod
    def _to_error(exc: Exception) -> PipelineErrorInfo:
        if isinstance(exc, PipelineError):
            return PipelineErrorInfo(code=exc.code, message=exc.message, details=exc.details)
        return PipelineErrorInfo(code="MIGRATION_FAILED", message="数据迁移失败，原目录未被修改。")

    @staticmethod
    def cleanup_pending_source(settings: Settings, settings_store: UserSettingsStore) -> None:
        """After a successful restart on the new root, reclaim the old copy."""
        if settings.managed_by == "environment" or not settings.allow_pending_cleanup:
            return
        current = settings_store.read()
        source = current.pending_source_cleanup
        if source is None:
            return
        source = source.expanduser().resolve(strict=False)
        target = settings.workspace_root.resolve()
        if source == target or source.is_relative_to(target) or target.is_relative_to(source):
            return
        if source.is_dir() and not WorkspaceMigrationService._is_reparse(source):
            try:
                shutil.rmtree(source, ignore_errors=False)
            except OSError:
                # The new root is already usable.  Keep the marker so a later
                # startup can reclaim files that are still open on Windows.
                return
        settings_store.write(current.model_copy(update={"pending_source_cleanup": None}))
