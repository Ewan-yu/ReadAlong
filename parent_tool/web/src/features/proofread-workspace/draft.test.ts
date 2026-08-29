import { describe, expect, it } from "vitest";

import { clampBox, mergeSentences, renumber, splitText, unionBoxes } from "./draft";

describe("proofread draft helpers", () => {
  it("renumbers sentences after destructive edits", () => {
    const result = renumber([
      { id: "s0008", seq: 8, page_no: 1, text: "One.", bbox: { x: 0, y: 0, width: 0.2, height: 0.1 }, shared_bbox: false, status: "sentence", suspect_words: [] },
    ]);
    expect(result[0]).toMatchObject({ id: "s0001", seq: 1 });
  });

  it("unions and constrains normalized boxes", () => {
    expect(unionBoxes([{ x: 0.1, y: 0.2, width: 0.2, height: 0.1 }, { x: 0.25, y: 0.15, width: 0.3, height: 0.2 }])).toEqual({ x: 0.1, y: 0.15, width: 0.45, height: 0.2 });
    expect(clampBox({ x: 0.99, y: -1, width: 1, height: 2 })).toEqual({ x: 0.98, y: 0, width: 0.02, height: 1 });
  });

  it("provides editable fragments when splitting text", () => {
    expect(splitText("Hello dear reader today.")).toEqual(["Hello dear", "reader today."]);
  });

  it("merges selected same-page sentences in reading order", () => {
    const result = mergeSentences([
      { id: "s0001", seq: 1, page_no: 1, text: "Mr.", bbox: { x: 0.1, y: 0.2, width: 0.1, height: 0.1 }, shared_bbox: true, status: "sentence", suspect_words: [] },
      { id: "s0002", seq: 2, page_no: 1, text: "Pintop is here.", bbox: { x: 0.2, y: 0.2, width: 0.2, height: 0.1 }, shared_bbox: true, status: "sentence", suspect_words: [] },
      { id: "s0003", seq: 3, page_no: 2, text: "Next page.", bbox: { x: 0.1, y: 0.1, width: 0.2, height: 0.1 }, shared_bbox: false, status: "sentence", suspect_words: [] },
    ], ["s0002", "s0001"]);
    expect(result).toHaveLength(2);
    expect(result[0]).toMatchObject({ text: "Mr. Pintop is here.", bbox: { x: 0.1, width: 0.3 }, shared_bbox: false });
  });
});
