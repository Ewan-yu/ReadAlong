import type { TimelineManualSentence, TimelineReviewSentence, TimelineWorkspace } from "../../api/client";

export const MINIMUM_WORD_DURATION_MS = 30;

const WORD_PATTERN = /[a-z0-9]+(?:['-][a-z0-9]+)*/g;

/** Mirror of the parent tool's normalized word counting (NFKC + casefold). */
export function normalizedWordCount(text: string): number {
  const folded = text.normalize("NFKC").toLowerCase().replace(/\u2019/g, "'");
  return (folded.match(WORD_PATTERN) ?? []).length;
}

export function formatClock(milliseconds?: number | null): string {
  if (milliseconds == null || !Number.isFinite(milliseconds)) return "--:--";
  const total = Math.floor(milliseconds / 1000);
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}.${String(Math.floor((milliseconds % 1000) / 100))}`;
}

export type DraftBoundaries = { start_ms: number; end_ms: number };

/** The parent's in-progress correction table, keyed by sentence id. */
export type CorrectionDraft = {
  /** Revision the draft was started from; a change resets the draft. */
  baseRevision: string;
  entries: Record<string, DraftBoundaries>;
};

export function buildDraft(workspace: TimelineWorkspace): CorrectionDraft {
  const entries: Record<string, DraftBoundaries> = {};
  for (const row of workspace.sentences) {
    if (row.status === "matched" && row.start_ms != null && row.end_ms != null) {
      entries[row.sentence_id] = { start_ms: row.start_ms, end_ms: row.end_ms };
    }
  }
  return { baseRevision: workspace.timeline_revision_id ?? "", entries };
}

export function isDraftDirty(workspace: TimelineWorkspace, draft: CorrectionDraft): boolean {
  const base = buildDraft(workspace);
  const keys = new Set([...Object.keys(base.entries), ...Object.keys(draft.entries)]);
  for (const key of keys) {
    const left = base.entries[key];
    const right = draft.entries[key];
    if (!left || !right) return true;
    if (left.start_ms !== right.start_ms || left.end_ms !== right.end_ms) return true;
  }
  return false;
}

export type RowView = {
  row: TimelineReviewSentence;
  /** Effective state after applying the draft. */
  state: "included" | "removed" | "missing" | "excluded";
  /** How the included boundaries differ from the generated timeline. */
  change: "unchanged" | "adjusted" | "added" | null;
  boundaries?: DraftBoundaries;
};

export function draftRows(workspace: TimelineWorkspace, draft: CorrectionDraft): RowView[] {
  return workspace.sentences.map((row) => {
    const entry = draft.entries[row.sentence_id];
    if (entry) {
      const change: RowView["change"] =
        row.status !== "matched"
          ? "added"
          : row.start_ms === entry.start_ms && row.end_ms === entry.end_ms
            ? "unchanged"
            : "adjusted";
      return { row, state: "included", change, boundaries: entry };
    }
    if (row.status === "matched") return { row, state: "removed", change: null };
    if (row.status === "confirmed_excluded") return { row, state: "excluded", change: null };
    return { row, state: "missing", change: null };
  });
}

export type DraftIssue = {
  sentenceId?: string;
  message: string;
  /** The sentence this issue conflicts with (for overlaps). */
  otherId?: string;
  overlapMs?: number;
};

export type OrderedBoundary = {
  sentenceId: string;
  row: TimelineReviewSentence;
  start_ms: number;
  end_ms: number;
};

/** Draft entries ordered by the proofread reading sequence. */
export function orderedBoundaries(
  workspace: TimelineWorkspace,
  draft: CorrectionDraft,
): OrderedBoundary[] {
  const byId = new Map(workspace.sentences.map((row) => [row.sentence_id, row]));
  return Object.entries(draft.entries)
    .map(([sentenceId, boundaries]) => ({ sentenceId, row: byId.get(sentenceId), ...boundaries }))
    .filter((item): item is OrderedBoundary & { row: TimelineReviewSentence } => Boolean(item.row))
    .sort((left, right) => left.row.seq - right.row.seq);
}

/** Reader contract: every word needs at least 30 ms of highlight time. */
export function minSpanMs(row: TimelineReviewSentence): number {
  return Math.max(normalizedWordCount(row.text) * MINIMUM_WORD_DURATION_MS, MINIMUM_WORD_DURATION_MS);
}

/** Front-end mirror of the backend publish gates, surfaced before publishing. */
export function draftIssues(
  workspace: TimelineWorkspace,
  draft: CorrectionDraft,
): DraftIssue[] {
  const ordered = orderedBoundaries(workspace, draft);
  const issues: DraftIssue[] = [];
  if (!ordered.length) return [{ message: "至少保留一句歌词。" }];
  let previousEnd = 0;
  let previousId: string | undefined;
  for (const item of ordered) {
    if (item.start_ms < previousEnd) {
      const overlapMs = previousEnd - item.start_ms;
      issues.push({
        sentenceId: item.sentenceId,
        otherId: previousId,
        overlapMs,
        message: `「${item.row.text}」与上一句 ${previousId ?? ""} 的标注重叠 ${(overlapMs / 1000).toFixed(1)} 秒。`,
      });
    }
    if (item.end_ms <= item.start_ms) {
      issues.push({ sentenceId: item.sentenceId, message: `「${item.row.text}」起止时间无效。` });
    }
    const duration = workspace.duration_ms;
    if (duration != null && item.end_ms > duration) {
      const overrun = ((item.end_ms - duration) / 1000).toFixed(1);
      issues.push({ sentenceId: item.sentenceId, message: `「${item.row.text}」超出音频长度 ${overrun} 秒。` });
    }
    previousEnd = Math.max(previousEnd, item.end_ms);
    previousId = item.sentenceId;
  }
  for (const item of ordered) {
    const wordCount = normalizedWordCount(item.row.text);
    if (wordCount > 0 && item.end_ms - item.start_ms < wordCount * MINIMUM_WORD_DURATION_MS) {
      issues.push({
        sentenceId: item.sentenceId,
        message: `「${item.row.text}」时间跨度不足以逐词高亮（约需 ${((wordCount * MINIMUM_WORD_DURATION_MS) / 1000).toFixed(1)} 秒）。`,
      });
    }
  }
  return issues;
}

/**
 * Resolve marked-boundary overlaps by splitting the overlap between the two
 * neighbours.  Narration speech is contiguous even when the parent's marks
 * cross, so moving each boundary by at most half the overlap is inaudible.
 * Sentences that cannot absorb the split keep their marks and stay flagged.
 */
export function autoFixOverlaps(
  workspace: TimelineWorkspace,
  draft: CorrectionDraft,
): CorrectionDraft | null {
  const ordered = orderedBoundaries(workspace, draft);
  if (ordered.length < 2) return null;
  const fixed: Record<string, DraftBoundaries> = { ...draft.entries };
  let changed = false;
  for (let index = 1; index < ordered.length; index += 1) {
    const previous = ordered[index - 1];
    const current = ordered[index];
    const a = fixed[previous.sentenceId];
    const b = fixed[current.sentenceId];
    if (!a || !b || b.start_ms >= a.end_ms) continue;
    const mid = Math.round((b.start_ms + a.end_ms) / 200) * 100;
    const minA = minSpanMs(previous.row);
    const minB = minSpanMs(current.row);
    if (mid - a.start_ms >= minA && b.end_ms - mid >= minB) {
      fixed[previous.sentenceId] = { ...a, end_ms: mid };
      fixed[current.sentenceId] = { ...b, start_ms: mid };
    } else if (b.end_ms - a.end_ms >= minB) {
      fixed[current.sentenceId] = { ...b, start_ms: a.end_ms };
    } else if (b.start_ms - a.start_ms >= minA) {
      fixed[previous.sentenceId] = { ...a, end_ms: b.start_ms };
    } else {
      continue;
    }
    changed = true;
  }
  return changed ? { ...draft, entries: fixed } : null;
}

export function toManualTable(
  workspace: TimelineWorkspace,
  draft: CorrectionDraft,
): TimelineManualSentence[] {
  const order = new Map(workspace.sentences.map((row) => [row.sentence_id, row.seq]));
  return Object.entries(draft.entries)
    .sort((left, right) => (order.get(left[0]) ?? 0) - (order.get(right[0]) ?? 0))
    .map(([sentenceId, boundaries]) => ({
      sentence_id: sentenceId,
      start_ms: boundaries.start_ms,
      end_ms: boundaries.end_ms,
    }));
}

/** Index of the row that should highlight at a playback position. */
export function activeRowIndex(views: RowView[], timeMs: number): number {
  let active = -1;
  for (let index = 0; index < views.length; index += 1) {
    const boundaries = views[index].boundaries;
    if (!boundaries) continue;
    if (timeMs >= boundaries.start_ms && timeMs < boundaries.end_ms) return index;
    if (timeMs >= boundaries.end_ms) active = index;
  }
  return timeMs >= 0 && views.length ? active : -1;
}

export const OMIT_REASON_HINTS: Record<string, string> = {
  no_similar_match: "原音里没有识别到与这句相近的朗读（也可能是封面、词表等本来就不读的文字）。",
  projection_failed: "识别到了相近朗读，但词级边界无法可靠映射。",
  internal_gap_exceeded: "句内词间隔过大，已按不可靠跳过。",
  excluded_by_review: "已在手工修正中确认不朗读。",
};

export function omitHint(row: TimelineReviewSentence): string {
  if (!row.reason) return "自动生成时未纳入歌词，请试听确认是漏识别还是本就不朗读。";
  return OMIT_REASON_HINTS[row.reason] ?? row.detail ?? "未纳入歌词。";
}

export type RowFilter = "all" | "missing" | "matched" | "excluded" | "changed";

export function filterRows(views: RowView[], filter: RowFilter): RowView[] {
  switch (filter) {
    case "missing":
      return views.filter((item) => item.state === "missing" || item.state === "removed");
    case "matched":
      return views.filter((item) => item.state === "included" && item.change !== "added");
    case "excluded":
      return views.filter((item) => item.state === "excluded");
    case "changed":
      return views.filter(
        (item) => item.change === "added" || item.change === "adjusted" || item.state === "removed",
      );
    default:
      return views;
  }
}
