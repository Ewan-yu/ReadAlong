import type { OcrSentence } from "../../api/client";

export type NormalizedBox = OcrSentence["bbox"];

export function renumber(sentences: OcrSentence[]): OcrSentence[] {
  return sentences.map((sentence, index) => ({
    ...sentence,
    id: `s${String(index + 1).padStart(4, "0")}`,
    seq: index + 1,
  }));
}

export function unionBoxes(boxes: NormalizedBox[]): NormalizedBox {
  const left = Math.min(...boxes.map((box) => box.x));
  const top = Math.min(...boxes.map((box) => box.y));
  const right = Math.max(...boxes.map((box) => box.x + box.width));
  const bottom = Math.max(...boxes.map((box) => box.y + box.height));
  const normalise = (value: number) => Number(value.toFixed(6));
  return { x: normalise(left), y: normalise(top), width: normalise(right - left), height: normalise(bottom - top) };
}

export function clampBox(box: NormalizedBox): NormalizedBox {
  const normalise = (value: number) => Number(value.toFixed(6));
  const x = Math.max(0, Math.min(0.98, box.x));
  const y = Math.max(0, Math.min(0.98, box.y));
  const width = Math.max(0.01, Math.min(1 - x, box.width));
  const height = Math.max(0.01, Math.min(1 - y, box.height));
  return { x: normalise(x), y: normalise(y), width: normalise(width), height: normalise(height) };
}

export function splitText(text: string): [string, string] {
  const words = text.trim().split(/\s+/);
  const midpoint = Math.max(1, Math.ceil(words.length / 2));
  return [words.slice(0, midpoint).join(" "), words.slice(midpoint).join(" ") || "请填写文本"];
}
