from __future__ import annotations

from app.models.errors import PipelineError
from app.models.ocr import OcrSentence, OcrSentences, SentenceStatus
from app.models.pipeline import StepId, StepResult
from app.models.proofread import AutoProofreadParams
from app.pipeline.definitions import StepRunContext
from app.pipeline.steps.ocr import EnglishSpellChecker


class AutoProofreadStep:
    step_id = StepId.PROOFREAD
    implementation_version = "proofread-interactive-v1"
    params_model = AutoProofreadParams

    def run(self, context: StepRunContext, params: AutoProofreadParams) -> StepResult:
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
        if params.sentences:
            if params.source_ocr_revision != source_root.name:
                raise PipelineError(
                    "OCR_REVISION_CHANGED",
                    "OCR 初稿已更新，请刷新校对台后重新提交。",
                    details={"expected": source_root.name, "received": params.source_ocr_revision},
                    status_code=409,
                )
            sentences = self._normalise_sentences(params.sentences)
            confirmed_pages = params.confirmed_pages
        elif params.accept_ocr_draft:
            sentences = draft.sentences
            confirmed_pages = tuple(page.page_no for page in draft.pages)
        else:
            raise PipelineError(
                "PROOFREAD_CONFIRMATION_REQUIRED",
                "请在校对台确认全部页面后再生成语音。",
                status_code=409,
            )

        invalid_pages = sorted(set(confirmed_pages) - {page.page_no for page in draft.pages})
        if invalid_pages:
            raise PipelineError(
                "PROOFREAD_PAGE_INVALID",
                "校对确认包含不存在的阅读页。",
                details={"page_nos": invalid_pages},
                status_code=422,
            )
        missing_pages = sorted({page.page_no for page in draft.pages} - set(confirmed_pages))
        if missing_pages:
            raise PipelineError(
                "PROOFREAD_PAGES_NOT_CONFIRMED",
                "仍有 OCR 页面未确认，请完成逐页校对。",
                details={"page_nos": missing_pages},
                status_code=409,
            )
        unresolved = [item.id for item in sentences if item.status is SentenceStatus.NEEDS_REVIEW]
        if unresolved:
            raise PipelineError(
                "PROOFREAD_REVIEW_REQUIRED",
                "OCR 初稿包含待确认项，不能自动接受。",
                details={"sentence_ids": unresolved},
                status_code=409,
            )
        final = draft.model_copy(update={"sentences": sentences, "confirmed_pages": confirmed_pages})
        target = context.staging_dir / "sentences_final.json"
        target.write_text(final.model_dump_json(indent=2), encoding="utf-8")
        context.progress(1, "OCR 句子校对已发布。")
        return StepResult(outputs=("sentences_final.json",), summary={"sentence_count": len(sentences)})

    @staticmethod
    def _normalise_sentences(sentences: tuple[OcrSentence, ...]) -> tuple[OcrSentence, ...]:
        normalised: list[OcrSentence] = []
        spell_checker = EnglishSpellChecker()
        for index, sentence in enumerate(sentences, start=1):
            text = sentence.text.strip()
            if not text:
                raise PipelineError(
                    "PROOFREAD_TEXT_EMPTY",
                    "句子文本不能为空。",
                    details={"sentence_id": sentence.id},
                    status_code=422,
                )
            normalised.append(
                sentence.model_copy(
                    update={
                        "id": f"s{index:04d}",
                        "seq": index,
                        "text": text,
                        "status": SentenceStatus.SENTENCE,
                        "suspect_words": spell_checker.suspects(text),
                    }
                )
            )
        return tuple(normalised)
