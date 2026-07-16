from __future__ import annotations

from app.models.errors import PipelineError
from app.models.ocr import OcrSentences, SentenceStatus
from app.models.pipeline import StepId, StepResult
from app.models.proofread import AutoProofreadParams
from app.pipeline.definitions import StepRunContext


class AutoProofreadStep:
    step_id = StepId.PROOFREAD
    implementation_version = "proofread-auto-accept-v1"
    params_model = AutoProofreadParams

    def run(self, context: StepRunContext, params: AutoProofreadParams) -> StepResult:
        if not params.accept_ocr_draft:
            raise PipelineError(
                "PROOFREAD_CONFIRMATION_REQUIRED",
                "请明确确认 OCR 初稿后再生成语音。",
                status_code=409,
            )
        try:
            source_root = context.dependency_outputs[StepId.OCR]
            draft = OcrSentences.model_validate_json(
                (source_root / "sentences.json").read_text(encoding="utf-8")
            )
        except (KeyError, OSError, ValueError) as exc:
            raise PipelineError(
                "PROOFREAD_INPUT_INVALID",
                "OCR 句子初稿不存在或已损坏，请重新执行 OCR。",
                status_code=409,
            ) from exc
        unresolved = [item.id for item in draft.sentences if item.status is SentenceStatus.NEEDS_REVIEW]
        if unresolved:
            raise PipelineError(
                "PROOFREAD_REVIEW_REQUIRED",
                "OCR 初稿包含待确认项，不能自动接受。",
                details={"sentence_ids": unresolved},
                status_code=409,
            )
        target = context.staging_dir / "sentences_final.json"
        target.write_text(draft.model_dump_json(indent=2), encoding="utf-8")
        context.progress(1, "已明确接受 OCR 初稿。")
        return StepResult(outputs=("sentences_final.json",), summary={"sentence_count": len(draft.sentences)})
