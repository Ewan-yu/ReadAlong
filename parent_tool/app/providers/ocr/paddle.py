from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from threading import Lock
from typing import Any, Protocol

import requests

from app.models.errors import PipelineError
from app.models.ocr import OcrParams
from app.pipeline.definitions import CancellationToken


JOB_URL = "https://paddleocr.aistudio-app.com/api/v2/ocr/jobs"
_TRANSIENT_STATUS = {429, 500, 502, 503, 504}


@dataclass(frozen=True)
class OcrProviderResult:
    raw_jsonl: str


class OcrProvider(Protocol):
    def recognize(
        self,
        image_path: Path,
        params: OcrParams,
        cancellation: CancellationToken,
    ) -> OcrProviderResult: ...


class PaddleOcrProvider:
    """PaddleOCR async-job client. Tokens are only read from the process environment."""

    def __init__(self, token: str | None = None, *, job_url: str = JOB_URL) -> None:
        self._token = token if token is not None else os.environ.get("PADDLE_TOKEN")
        self._job_url = job_url.rstrip("/")
        self._submit_lock = Lock()
        self._last_submit_at = 0.0

    def recognize(
        self,
        image_path: Path,
        params: OcrParams,
        cancellation: CancellationToken,
    ) -> OcrProviderResult:
        if not self._token:
            raise PipelineError(
                "OCR_PROVIDER_NOT_CONFIGURED",
                "尚未配置 PaddleOCR Token；请设置 PADDLE_TOKEN 后重试。",
                status_code=422,
            )
        job_id = self._submit(image_path, params, cancellation)
        result_url = self._poll(job_id, params, cancellation)
        response = self._request("get", result_url, params, cancellation, timeout=120)
        if response.status_code != 200:
            raise PipelineError("OCR_RESPONSE_DOWNLOAD_FAILED", "OCR 响应下载失败，请重试。", status_code=502)
        return OcrProviderResult(raw_jsonl=response.text)

    def _submit(self, image_path: Path, params: OcrParams, cancellation: CancellationToken) -> str:
        with self._submit_lock:
            remaining = params.request_interval_seconds - (time.monotonic() - self._last_submit_at)
            if remaining > 0:
                self._wait(remaining, cancellation)
            cancellation.raise_if_cancelled()
            with image_path.open("rb") as image:
                response = self._request(
                    "post",
                    self._job_url,
                    params,
                    cancellation,
                    headers={"Authorization": f"bearer {self._token}"},
                    data={
                        "model": params.model.value,
                        "optionalPayload": json.dumps(
                            {
                                "useDocOrientationClassify": False,
                                "useDocUnwarping": False,
                                "useChartRecognition": False,
                            }
                        ),
                    },
                    files={"file": image},
                    timeout=180,
                )
            self._last_submit_at = time.monotonic()
        if response.status_code != 200:
            raise PipelineError("OCR_SUBMIT_FAILED", "OCR 任务提交失败，请检查 Token 和网络后重试。", status_code=502)
        try:
            return str(response.json()["data"]["jobId"])
        except (KeyError, TypeError, ValueError) as exc:
            raise PipelineError("OCR_RESPONSE_INVALID", "OCR 服务返回了无法识别的任务响应。", status_code=502) from exc

    def _poll(self, job_id: str, params: OcrParams, cancellation: CancellationToken) -> str:
        deadline = time.monotonic() + params.poll_timeout_seconds
        headers = {"Authorization": f"bearer {self._token}"}
        while time.monotonic() < deadline:
            response = self._request("get", f"{self._job_url}/{job_id}", params, cancellation, headers=headers, timeout=30)
            if response.status_code != 200:
                raise PipelineError("OCR_POLL_FAILED", "OCR 任务状态查询失败，请重试。", status_code=502)
            try:
                payload: dict[str, Any] = response.json()["data"]
                state = payload["state"]
            except (KeyError, TypeError, ValueError) as exc:
                raise PipelineError("OCR_RESPONSE_INVALID", "OCR 服务返回了无法识别的状态响应。", status_code=502) from exc
            if state == "done":
                try:
                    return str(payload["resultUrl"]["jsonUrl"])
                except (KeyError, TypeError) as exc:
                    raise PipelineError("OCR_RESPONSE_INVALID", "OCR 成功响应缺少结果文件。", status_code=502) from exc
            if state == "failed":
                raise PipelineError(
                    "OCR_PROVIDER_FAILED",
                    "OCR 服务未能识别此页，请稍后重试或在校对台手动录入。",
                    details={"provider_message": str(payload.get("errorMsg", ""))[:500]},
                    status_code=502,
                )
            self._wait(params.poll_interval_seconds, cancellation)
        raise PipelineError("OCR_TIMEOUT", "等待 OCR 服务结果超时，请重试。", status_code=504)

    @staticmethod
    def _wait(seconds: float, cancellation: CancellationToken) -> None:
        end = time.monotonic() + seconds
        while True:
            cancellation.raise_if_cancelled()
            remaining = end - time.monotonic()
            if remaining <= 0:
                return
            time.sleep(min(remaining, 0.2))

    @staticmethod
    def _retry_after(response: requests.Response, attempt: int) -> float:
        value = response.headers.get("Retry-After")
        try:
            return max(0.5, float(value)) if value else 1.0 * (2**attempt)
        except ValueError:
            return 1.0 * (2**attempt)

    def _request(self, method: str, url: str, params: OcrParams, cancellation: CancellationToken, **kwargs: Any) -> requests.Response:
        for attempt in range(params.max_attempts):
            cancellation.raise_if_cancelled()
            try:
                response = requests.request(method, url, **kwargs)
            except requests.RequestException as exc:
                if attempt == params.max_attempts - 1:
                    raise PipelineError("OCR_NETWORK_ERROR", "无法连接 OCR 服务，请检查网络后重试。", status_code=502) from exc
                self._wait(1.0 * (2**attempt), cancellation)
                continue
            if response.status_code not in _TRANSIENT_STATUS or attempt == params.max_attempts - 1:
                return response
            self._wait(self._retry_after(response, attempt), cancellation)
        raise AssertionError("unreachable")


class ReplayOcrProvider:
    """Deterministic provider for tests and recorded-response regression checks."""

    def __init__(self, responses: dict[str, str | Path]) -> None:
        self._responses = responses

    def recognize(
        self,
        image_path: Path,
        params: OcrParams,
        cancellation: CancellationToken,
    ) -> OcrProviderResult:
        del params
        cancellation.raise_if_cancelled()
        try:
            response = self._responses[image_path.name]
        except KeyError as exc:
            raise PipelineError(
                "OCR_REPLAY_MISSING",
                "找不到此页对应的 OCR 回放响应。",
                details={"image": image_path.name},
                status_code=422,
            ) from exc
        raw_jsonl = response.read_text(encoding="utf-8") if isinstance(response, Path) else response
        return OcrProviderResult(raw_jsonl=raw_jsonl)
