from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from PIL import Image

from app.models.errors import PipelineError
from app.models.ocr import (
    BoundingBox,
    OcrPage,
    OcrParams,
    OcrSentence,
    OcrSentences,
    SentenceStatus,
    SuspectKind,
    SuspectWord,
)
from app.models.pages import PagePlan
from app.models.pipeline import StepId, StepResult
from app.pipeline.definitions import StepRunContext
from app.providers.ocr import OcrProvider


_TEXT_LABELS = {"text", "paragraph_title"}
_WORDS = re.compile(r"[A-Za-z]+(?:['’-][A-Za-z]+)*")
_SYMBOLS_ONLY = re.compile(r"^[\W_]+$", re.UNICODE)
_CLOSING_QUOTES = "\"”’"


class EnglishSpellChecker:
    """Small adapter so spelling policy remains testable and package-independent."""

    def __init__(self) -> None:
        self._dictionary: Any | None = None

    def suspects(self, text: str) -> tuple[SuspectWord, ...]:
        if self._dictionary is None:
            self._dictionary = self._load_dictionary()
        words = tuple(dict.fromkeys(match.group(0) for match in _WORDS.finditer(text)))
        unknown = self._dictionary.unknown(word.casefold() for word in words)
        return tuple(
            SuspectWord(
                word=word,
                kind=SuspectKind.PROPER_NOUN if word[0].isupper() else SuspectKind.SPELLING,
            )
            for word in words
            if word.casefold() in unknown and word.casefold() not in {"i", "a"}
        )

    @staticmethod
    def _load_dictionary() -> Any:
        try:
            from spellchecker import SpellChecker
        except ImportError as exc:  # pragma: no cover - guarded by project dependency
            raise PipelineError(
                "SPELLCHECKER_UNAVAILABLE",
                "英文拼写检查组件未安装，请重新安装家长端依赖。",
                status_code=500,
            ) from exc
        return SpellChecker(language="en")


@dataclass(frozen=True)
class RawBlock:
    text: str
    bbox: tuple[float, float, float, float]


class OcrStep:
    step_id = StepId.OCR
    implementation_version = "ocr-v1"
    params_model = OcrParams

    def __init__(self, provider: OcrProvider, spell_checker: EnglishSpellChecker | None = None) -> None:
        self._provider = provider
        self._spell_checker = spell_checker or EnglishSpellChecker()

    def run(self, context: StepRunContext, params: OcrParams) -> StepResult:
        try:
            pages_root = context.dependency_outputs[StepId.PAGES]
        except KeyError as exc:
            raise PipelineError("OCR_INPUT_MISSING", "缺少已完成的页面处理结果。", status_code=409) from exc
        plan = self._load_plan(pages_root)
        page_outputs = tuple(output for entry in plan.pages for output in entry.outputs)
        sentences: list[OcrSentence] = []
        pages: list[OcrPage] = []
        output_paths: list[str] = []
        total = max(len(page_outputs), 1)

        for index, output in enumerate(page_outputs, start=1):
            context.cancellation.raise_if_cancelled()
            source_image = pages_root / output.ocr_image
            if not source_image.is_file():
                raise PipelineError(
                    "OCR_INPUT_MISSING",
                    "页面处理结果缺少 OCR 图片，请重新执行页面处理。",
                    details={"page_no": output.page_no, "path": output.ocr_image},
                    status_code=409,
                )
            result = self._provider.recognize(source_image, params, context.cancellation)
            response_path = f"responses/p{output.page_no:04d}.jsonl"
            target = context.staging_dir / response_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(result.raw_jsonl, encoding="utf-8")
            output_paths.append(response_path)
            with Image.open(source_image) as image:
                width, height = image.size
            blocks = self._parse_blocks(result.raw_jsonl, width, height)
            created_before = len(sentences)
            for block in blocks:
                fragments = self._split_sentences(block.text)
                status = self._status_for(block.text)
                if status is SentenceStatus.NEEDS_REVIEW:
                    fragments = (block.text.strip(),)
                for fragment in fragments:
                    if not fragment:
                        continue
                    sequence = len(sentences) + 1
                    sentences.append(
                        OcrSentence(
                            id=f"s{sequence:04d}",
                            page_no=output.page_no,
                            seq=sequence,
                            text=fragment,
                            bbox=self._normalise_bbox(block.bbox, width, height),
                            shared_bbox=len(fragments) > 1,
                            status=status,
                            suspect_words=(
                                () if status is SentenceStatus.NEEDS_REVIEW else self._spell_checker.suspects(fragment)
                            ),
                        )
                    )
            pages.append(
                OcrPage(
                    page_no=output.page_no,
                    ocr_image=output.ocr_image,
                    response_path=response_path,
                    blocks_seen=len(blocks),
                    sentences_created=len(sentences) - created_before,
                )
            )
            context.progress(index / total, f"已识别阅读页 {index}/{total}。")

        document = OcrSentences(
            source_pages_revision=pages_root.name,
            params=params,
            pages=tuple(pages),
            sentences=tuple(sentences),
        )
        (context.staging_dir / "sentences.json").write_text(
            document.model_dump_json(indent=2), encoding="utf-8"
        )
        context.progress(1, "OCR 与句子切分完成。")
        return StepResult(
            outputs=("sentences.json", *output_paths),
            summary={"page_count": len(pages), "sentence_count": len(sentences)},
        )

    @staticmethod
    def _load_plan(pages_root: Path) -> PagePlan:
        try:
            return PagePlan.model_validate_json((pages_root / "page_plan.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise PipelineError(
                "OCR_INPUT_INVALID",
                "页面处理结果的 page_plan.json 损坏，请重新执行页面处理。",
                status_code=409,
            ) from exc

    @classmethod
    def _parse_blocks(cls, raw_jsonl: str, width: int, height: int) -> tuple[RawBlock, ...]:
        try:
            records = [json.loads(line) for line in raw_jsonl.splitlines() if line.strip()]
        except json.JSONDecodeError as exc:
            raise PipelineError("OCR_RESPONSE_INVALID", "OCR 响应不是合法 JSONL。", status_code=502) from exc
        if not records:
            raise PipelineError("OCR_RESPONSE_INVALID", "OCR 响应为空。", status_code=502)
        blocks: list[RawBlock] = []
        for record in records:
            for item in cls._iter_layouts(record):
                pruned = item.get("prunedResult")
                candidates = pruned.get("parsing_res_list", ()) if isinstance(pruned, dict) else ()
                if not isinstance(candidates, list):
                    continue
                for candidate in candidates:
                    if not isinstance(candidate, dict):
                        continue
                    label = str(candidate.get("block_label", candidate.get("label", ""))).casefold()
                    text = candidate.get("block_content", candidate.get("text"))
                    bbox = candidate.get("block_bbox", candidate.get("bbox"))
                    parsed = cls._pixel_bbox(bbox, width, height)
                    if label in _TEXT_LABELS and isinstance(text, str) and text.strip() and parsed:
                        blocks.append(RawBlock(text=text.strip(), bbox=parsed))
        return tuple(sorted(blocks, key=lambda block: (block.bbox[1], block.bbox[0])))

    @staticmethod
    def _iter_layouts(record: dict[str, Any]) -> Iterable[dict[str, Any]]:
        result = record.get("result", record)
        if not isinstance(result, dict):
            return ()
        layouts = result.get("layoutParsingResults")
        if isinstance(layouts, list) and layouts:
            return (item for item in layouts if isinstance(item, dict))
        return (result,)

    @staticmethod
    def _pixel_bbox(value: Any, page_width: int, page_height: int) -> tuple[float, float, float, float] | None:
        if not isinstance(value, list) or len(value) != 4 or not all(isinstance(item, (int, float)) for item in value):
            return None
        x1, y1, third, fourth = (float(item) for item in value)
        # Paddle layout blocks use [x1, y1, x2, y2]. Accept [x, y, width, height]
        # too, because recorded variants of provider responses use that representation.
        x2, y2 = (third, fourth) if third > x1 and fourth > y1 else (x1 + third, y1 + fourth)
        x1, x2 = max(0, min(page_width, x1)), max(0, min(page_width, x2))
        y1, y2 = max(0, min(page_height, y1)), max(0, min(page_height, y2))
        if x2 <= x1 or y2 <= y1:
            return None
        return x1, y1, x2 - x1, y2 - y1

    @staticmethod
    def _normalise_bbox(bbox: tuple[float, float, float, float], width: int, height: int) -> BoundingBox:
        x, y, box_width, box_height = bbox
        return BoundingBox(x=round(x / width, 6), y=round(y / height, 6), width=round(box_width / width, 6), height=round(box_height / height, 6))

    @staticmethod
    def _status_for(text: str) -> SentenceStatus:
        stripped = text.strip()
        return SentenceStatus.NEEDS_REVIEW if len(stripped) < 2 or _SYMBOLS_ONLY.fullmatch(stripped) else SentenceStatus.SENTENCE

    @staticmethod
    def _split_sentences(text: str) -> tuple[str, ...]:
        fragments: list[str] = []
        start = 0
        for index, char in enumerate(text):
            if char not in ".?!":
                continue
            following = index + 1
            while following < len(text) and text[following] in _CLOSING_QUOTES:
                following += 1
            if following < len(text) and not text[following].isspace():
                continue
            fragment = text[start:following].strip()
            if fragment:
                fragments.append(fragment)
            start = following
        tail = text[start:].strip()
        if tail:
            fragments.append(tail)
        return tuple(fragments)
