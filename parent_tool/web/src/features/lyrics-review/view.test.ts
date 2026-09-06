import { describe, expect, it } from "vitest";

import type { TimelineReviewSentence, TimelineWorkspace } from "../../api/client";
import {
  activeRowIndex,
  autoFixOverlaps,
  buildDraft,
  draftIssues,
  draftRows,
  filterRows,
  formatClock,
  isDraftDirty,
  minSpanMs,
  normalizedWordCount,
  omitHint,
  orderedBoundaries,
  toManualTable,
} from "./view";

function sentence(overrides: Partial<TimelineReviewSentence>): TimelineReviewSentence {
  return {
    sentence_id: "s0001",
    page_no: 1,
    seq: 1,
    text: "Hello world.",
    status: "matched",
    source: "asr",
    start_ms: 0,
    end_ms: 800,
    reason: null,
    detail: null,
    previous_matched_id: null,
    next_matched_id: null,
    nearby_asr: [],
    ...overrides,
  };
}

function workspace(sentences: TimelineReviewSentence[], durationMs = 2000): TimelineWorkspace {
  return {
    available: true,
    status: "ready",
    timeline_revision_id: "r-timeline-1",
    alignment_strategy: "discovery_projection",
    whisper_model: "tiny",
    duration_ms: durationMs,
    matched_count: sentences.filter((item) => item.status === "matched").length,
    suspect_missing_count: sentences.filter((item) => item.status === "suspect_missing").length,
    confirmed_excluded_count: sentences.filter((item) => item.status === "confirmed_excluded").length,
    sentences,
  };
}

describe("normalizedWordCount", () => {
  it("counts words the way the parent tool normalises them", () => {
    expect(normalizedWordCount("Hello world.")).toBe(2);
    expect(normalizedWordCount("Frog’s net—right?")).toBe(3);
    expect(normalizedWordCount("grand+pa's")).toBe(2);
    expect(normalizedWordCount("...")).toBe(0);
  });
});

describe("formatClock", () => {
  it("renders minutes, seconds and tenths", () => {
    expect(formatClock(0)).toBe("0:00.0");
    expect(formatClock(65_430)).toBe("1:05.4");
    expect(formatClock(null)).toBe("--:--");
  });
});

describe("draft", () => {
  const base = workspace([
    sentence({ sentence_id: "s0001", seq: 1, start_ms: 0, end_ms: 800 }),
    sentence({ sentence_id: "s0002", seq: 2, text: "Skipped words.", status: "suspect_missing", start_ms: null, end_ms: null }),
    sentence({ sentence_id: "s0003", seq: 3, text: "Good night.", start_ms: 1000, end_ms: 1800 }),
  ]);

  it("starts from the matched rows and reports clean", () => {
    const draft = buildDraft(base);
    expect(Object.keys(draft.entries)).toEqual(["s0001", "s0003"]);
    expect(isDraftDirty(base, draft)).toBe(false);
  });

  it("detects additions, adjustments and removals as dirty", () => {
    const added = buildDraft(base);
    added.entries.s0002 = { start_ms: 850, end_ms: 950 };
    expect(isDraftDirty(base, added)).toBe(true);

    const adjusted = buildDraft(base);
    adjusted.entries.s0003 = { start_ms: 1000, end_ms: 1900 };
    expect(isDraftDirty(base, adjusted)).toBe(true);

    const removed = buildDraft(base);
    delete removed.entries.s0003;
    expect(isDraftDirty(base, removed)).toBe(true);
  });

  it("exposes effective row states after the draft", () => {
    const draft = buildDraft(base);
    draft.entries.s0002 = { start_ms: 850, end_ms: 950 };
    delete draft.entries.s0003;
    const views = draftRows(base, draft);
    expect(views.map((item) => [item.state, item.change])).toEqual([
      ["included", "unchanged"],
      ["included", "added"],
      ["removed", null],
    ]);
  });

  it("flags overlap, short spans and audio overrun before publishing", () => {
    const draft = buildDraft(base);
    draft.entries.s0002 = { start_ms: 700, end_ms: 720 };
    const issues = draftIssues(base, draft);
    expect(issues.some((issue) => issue.message.includes("重叠"))).toBe(true);
    expect(issues.some((issue) => issue.message.includes("不足以逐词高亮"))).toBe(true);

    const overlap = issues.find((issue) => issue.otherId);
    expect(overlap?.sentenceId).toBe("s0002");
    expect(overlap?.otherId).toBe("s0001");
    expect(overlap?.overlapMs).toBe(100);

    const overrun = buildDraft(base);
    overrun.entries.s0003 = { start_ms: 1500, end_ms: 2600 };
    expect(draftIssues(base, overrun).some((issue) => issue.message.includes("超出音频长度"))).toBe(true);

    expect(draftIssues(base, buildDraft(base))).toEqual([]);
  });

  it("splits the crossed boundary between neighbours when auto-fixing overlaps", () => {
    const draft = buildDraft(base);
    draft.entries.s0002 = { start_ms: 700, end_ms: 1500 };

    const fixed = autoFixOverlaps(base, draft);

    expect(fixed).not.toBeNull();
    expect(fixed!.entries.s0001.end_ms).toBeLessThanOrEqual(fixed!.entries.s0002.start_ms);
    // The crossed marks (800 / 700) meet at the 100 ms-rounded midpoint.
    expect(fixed!.entries.s0001.end_ms).toBe(800);
    expect(fixed!.entries.s0002.start_ms).toBe(800);
    expect(draftIssues(base, fixed!)).toEqual([]);

    expect(autoFixOverlaps(base, buildDraft(base))).toBeNull();
  });

  it("leaves inverted marks untouched for manual resolution", () => {
    // Marks in reverse reading order cannot be fixed by splitting a boundary.
    const draft = buildDraft(base);
    draft.entries.s0002 = { start_ms: 1790, end_ms: 1900 };
    draft.entries.s0003 = { start_ms: 1000, end_ms: 1800 };

    expect(autoFixOverlaps(base, draft)).toBeNull();
    const issues = draftIssues(base, draft);
    expect(issues.some((issue) => issue.otherId === "s0002")).toBe(true);
  });

  it("computes the reader word-span floor", () => {
    expect(minSpanMs(base.sentences[0])).toBe(60);
    expect(minSpanMs(base.sentences[1])).toBeGreaterThanOrEqual(30);
  });

  it("serialises the manual table in reading order", () => {
    const draft = buildDraft(base);
    draft.entries.s0002 = { start_ms: 850, end_ms: 950 };
    expect(toManualTable(base, draft)).toEqual([
      { sentence_id: "s0001", start_ms: 0, end_ms: 800 },
      { sentence_id: "s0002", start_ms: 850, end_ms: 950 },
      { sentence_id: "s0003", start_ms: 1000, end_ms: 1800 },
    ]);
  });
});

describe("activeRowIndex", () => {
  const views = draftRows(
    workspace([
      sentence({ sentence_id: "s0001", start_ms: 0, end_ms: 800 }),
      sentence({ sentence_id: "s0002", seq: 2, text: "Gap words.", status: "suspect_missing", start_ms: null, end_ms: null }),
      sentence({ sentence_id: "s0003", seq: 3, text: "Good night.", start_ms: 1000, end_ms: 1800 }),
    ]),
    buildDraft(
      workspace([
        sentence({ sentence_id: "s0001", start_ms: 0, end_ms: 800 }),
        sentence({ sentence_id: "s0002", seq: 2, text: "Gap words.", status: "suspect_missing", start_ms: null, end_ms: null }),
        sentence({ sentence_id: "s0003", seq: 3, text: "Good night.", start_ms: 1000, end_ms: 1800 }),
      ]),
    ),
  );

  it("highlights the sentence containing the playhead and keeps the last one after it", () => {
    expect(activeRowIndex(views, 400)).toBe(0);
    expect(activeRowIndex(views, 900)).toBe(0);
    expect(activeRowIndex(views, 1200)).toBe(2);
    expect(activeRowIndex(views, 1900)).toBe(2);
  });
});

describe("filterRows", () => {
  const rows = draftRows(
    workspace([
      sentence({ sentence_id: "s0001", start_ms: 0, end_ms: 800 }),
      sentence({ sentence_id: "s0002", seq: 2, text: "Missing one.", status: "suspect_missing", start_ms: null, end_ms: null }),
      sentence({ sentence_id: "s0003", seq: 3, text: "Cover words.", status: "confirmed_excluded", start_ms: null, end_ms: null }),
    ]),
    { baseRevision: "", entries: { s0001: { start_ms: 0, end_ms: 800 } } },
  );

  it("groups the review-relevant states", () => {
    expect(filterRows(rows, "missing").map((item) => item.row.sentence_id)).toEqual(["s0002"]);
    expect(filterRows(rows, "matched").map((item) => item.row.sentence_id)).toEqual(["s0001"]);
    expect(filterRows(rows, "excluded").map((item) => item.row.sentence_id)).toEqual(["s0003"]);
    expect(filterRows(rows, "all")).toHaveLength(3);
  });
});

describe("omitHint", () => {
  it("explains known reasons and falls back for legacy rows", () => {
    expect(omitHint(sentence({ status: "suspect_missing", reason: "no_similar_match", start_ms: null, end_ms: null }))).toContain("没有识别到");
    expect(omitHint(sentence({ status: "suspect_missing", reason: null, start_ms: null, end_ms: null }))).toContain("试听确认");
  });
});
