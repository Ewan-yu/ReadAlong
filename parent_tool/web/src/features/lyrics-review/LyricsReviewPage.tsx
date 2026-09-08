import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import {
  ArrowLeft,
  Check,
  CircleAlert,
  Clock,
  EyeOff,
  ListMusic,
  LoaderCircle,
  Pause,
  PencilLine,
  Play,
  RotateCcw,
  Trash2,
  Undo2,
  Wand2,
} from "lucide-react";
import { memo, type Ref, useEffect, useMemo, useRef, useState } from "react";

import {
  originalAudioSourceUrl,
  publishTimelineCorrection,
  updateTimelineReview,
  type JobSnapshot,
  type TimelineReviewSentence,
} from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { bookStateQuery, exportWorkspaceQuery, originalAudioWorkspaceQuery, timelineWorkspaceQuery } from "../../api/queries";
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
  omitHint,
  toManualTable,
  type CorrectionDraft,
  type DraftIssue,
  type RowFilter,
} from "./view";
import styles from "./LyricsReviewPage.module.css";

type EditingState = { row: TimelineReviewSentence; startMs: number; endMs: number };

const FILTERS: Array<{ id: RowFilter; label: string }> = [
  { id: "all", label: "全部" },
  { id: "missing", label: "待处理" },
  { id: "matched", label: "已匹配" },
  { id: "excluded", label: "不朗读" },
  { id: "changed", label: "本次修改" },
];

function stateBadge(view: ReturnType<typeof draftRows>[number]) {
  if (view.state === "included") {
    if (view.change === "added") return { label: "手工补录", tone: "manual" };
    if (view.change === "adjusted") return { label: "已手工调整", tone: "manual" };
    return { label: "已匹配", tone: "ok" };
  }
  if (view.state === "removed") return { label: "已移除", tone: "removed" };
  if (view.state === "excluded") return { label: "不朗读（已确认）", tone: "muted" };
  return { label: "疑似缺失", tone: "warn" };
}

type RowHandlers = {
  onSeek: (startMs: number) => void;
  onPlayRange: (startMs: number, endMs: number) => void;
  onEdit: (row: TimelineReviewSentence) => void;
  onRemove: (row: TimelineReviewSentence) => void;
  onRestore: (row: TimelineReviewSentence) => void;
  onConfirmSkip: (row: TimelineReviewSentence) => void;
  onUnconfirmSkip: (row: TimelineReviewSentence) => void;
  onFixPush: (issue: DraftIssue) => void;
  onFixShortenOther: (issue: DraftIssue) => void;
};

/**
 * Memoised so the 4 Hz playhead update only re-renders the rows whose active
 * state changed, not the whole sentence list of a long book.
 */
const SentenceRow = memo(function SentenceRow({
  view,
  issue,
  active,
  flash,
  canShortenOther,
  busy,
  handlers,
  rowRef,
}: {
  view: ReturnType<typeof draftRows>[number];
  issue?: DraftIssue;
  active: boolean;
  flash: boolean;
  canShortenOther: boolean;
  busy: boolean;
  handlers: RowHandlers;
  rowRef?: Ref<HTMLDivElement>;
}) {
  const badge = stateBadge(view);
  const boundaries = view.boundaries;
  const row = view.row;
  return (
    <div
      id={`lyrics-row-${row.sentence_id}`}
      ref={rowRef}
      className={styles.row}
      data-state={view.state}
      data-change={view.change ?? undefined}
      data-active={active || undefined}
      data-flash={flash || undefined}
    >
      <div className={styles.rowMeta}>
        <b data-tone={badge.tone}>{badge.label}</b>
        <span>{row.sentence_id} · 第 {row.page_no} 页</span>
        <span>{boundaries ? `${formatClock(boundaries.start_ms)} – ${formatClock(boundaries.end_ms)}` : "—"}</span>
      </div>
      <p
        className={styles.rowText}
        role="button"
        tabIndex={0}
        title="点击把播放位置跳到本句开头"
        onClick={() => boundaries && handlers.onSeek(boundaries.start_ms)}
        onKeyDown={(event) => {
          if ((event.key === "Enter" || event.key === " ") && boundaries) {
            event.preventDefault();
            handlers.onSeek(boundaries.start_ms);
          }
        }}
      >
        {row.text}
      </p>
      {issue?.otherId && (
        <div className={styles.rowConflict} role="status">
          <CircleAlert />
          <span>与 {issue.otherId} 的标注重叠 {((issue.overlapMs ?? 0) / 1000) > 0 ? `${((issue.overlapMs ?? 0) / 1000).toFixed(1)} 秒` : ""}，可一键修正：</span>
          <button type="button" onClick={() => handlers.onFixPush(issue)}>本句起点顺延</button>
          {canShortenOther && (
            <button type="button" onClick={() => handlers.onFixShortenOther(issue)}>把 {issue.otherId} 终点提前</button>
          )}
        </div>
      )}
      {view.state === "missing" && <p className={styles.rowHint}>{omitHint(row)}</p>}
      <div className={styles.rowActions}>
        {boundaries && (
          <>
            <button type="button" onClick={() => handlers.onPlayRange(boundaries.start_ms, boundaries.end_ms)}><Play />试听本句</button>
            <button type="button" onClick={() => handlers.onEdit(row)}><PencilLine />调整时间</button>
            {view.change === "added" || row.status !== "matched" ? (
              <button type="button" onClick={() => handlers.onRemove(row)}><Trash2 />不纳入</button>
            ) : (
              <button type="button" onClick={() => handlers.onRemove(row)}><Trash2 />移除</button>
            )}
          </>
        )}
        {view.state === "removed" && (
          <button type="button" onClick={() => handlers.onRestore(row)}><Undo2 />恢复</button>
        )}
        {view.state === "missing" && (
          <>
            <button type="button" onClick={() => handlers.onEdit(row)}><PencilLine />补录时间</button>
            <button type="button" disabled={busy} onClick={() => handlers.onConfirmSkip(row)}><EyeOff />原音不读这句</button>
          </>
        )}
        {view.state === "excluded" && (
          <>
            <button type="button" disabled={busy} onClick={() => handlers.onUnconfirmSkip(row)}><Undo2 />取消不朗读</button>
            <button type="button" onClick={() => handlers.onEdit(row)}><PencilLine />补录时间</button>
          </>
        )}
      </div>
    </div>
  );
});

/** Seconds-based time field: free typing, commits on blur/Enter, snaps to 0.1s. */
function TimeInput({ valueMs, onCommit }: { valueMs: number; onCommit: (ms: number) => void }) {
  const [text, setText] = useState(() => (valueMs / 1000).toFixed(1));
  const [focused, setFocused] = useState(false);
  useEffect(() => {
    if (!focused) setText((valueMs / 1000).toFixed(1));
  }, [focused, valueMs]);
  const commit = () => {
    const parsed = Number.parseFloat(text);
    const next = Number.isFinite(parsed) ? Math.max(0, Math.round(parsed * 10) * 100) : valueMs;
    onCommit(next);
    setText((next / 1000).toFixed(1));
  };
  return (
    <span className={styles.timeBox}>
      <input
        className={styles.timeInput}
        inputMode="decimal"
        aria-label="时间（秒）"
        value={text}
        onChange={(event) => setText(event.target.value)}
        onFocus={() => setFocused(true)}
        onBlur={() => {
          setFocused(false);
          commit();
        }}
        onKeyDown={(event) => {
          if (event.key === "Enter") (event.target as HTMLInputElement).blur();
        }}
      />
      <span className={styles.timeUnit}>秒</span>
    </span>
  );
}

export function LyricsReviewPage() {
  const { bookId } = useParams({ strict: false }) as { bookId: string };
  const client = useQueryClient();
  const query = useQuery(timelineWorkspaceQuery(bookId));
  const workspace = query.data;

  const [draft, setDraft] = useState<CorrectionDraft>();
  const [filter, setFilter] = useState<RowFilter>("all");
  const [pageFilter, setPageFilter] = useState<number | "all">("all");
  const [playing, setPlaying] = useState(false);
  const [nowMs, setNowMs] = useState(0);
  const [editing, setEditing] = useState<EditingState>();
  const [publishJob, setPublishJob] = useState<JobSnapshot>();
  const [publishedNotice, setPublishedNotice] = useState<string>();
  const [flashId, setFlashId] = useState<string>();
  const audioRef = useRef<HTMLAudioElement>(null);
  const rangeRef = useRef<number | undefined>(undefined);
  const activeRef = useRef<HTMLDivElement>(null);
  // Handlers read the live playhead from a ref so their identity stays stable
  // and memoised rows are not re-rendered by the 4 Hz timeupdate tick.
  const nowRef = useRef(0);

  // The revision id is the draft's reset boundary, mirroring the proofread page.
  useEffect(() => {
    if (!workspace) return;
    const revision = workspace.timeline_revision_id ?? "";
    setDraft((current) =>
      !current || current.baseRevision !== revision ? buildDraft(workspace) : current,
    );
    // The published notice deliberately survives the post-publish refetch: the
    // revision change would otherwise clear the "please re-export" hint in the
    // same render that shows it. It is cleared by the next edit instead.
  }, [workspace?.timeline_revision_id, workspace?.status]); // eslint-disable-line react-hooks/exhaustive-deps

  const views = useMemo(() => (workspace && draft ? draftRows(workspace, draft) : []), [draft, workspace]);
  const issues = useMemo(
    () => (workspace && draft ? draftIssues(workspace, draft) : []),
    [draft, workspace],
  );
  const issuesByRow = useMemo(() => {
    const map = new Map<string, DraftIssue>();
    for (const issue of issues) {
      if (issue.sentenceId) map.set(issue.sentenceId, issue);
    }
    return map;
  }, [issues]);
  const overlapCount = issues.filter((issue) => issue.otherId).length;
  const dirty = workspace && draft ? isDraftDirty(workspace, draft) : false;
  const activeIndex = activeRowIndex(views, nowMs);
  const visible = useMemo(() => {
    const filtered = filterRows(views, filter);
    return pageFilter === "all" ? filtered : filtered.filter((item) => item.row.page_no === pageFilter);
  }, [filter, pageFilter, views]);
  const pages = useMemo(
    () => Array.from(new Set((workspace?.sentences ?? []).map((row) => row.page_no))).sort((a, b) => a - b),
    [workspace],
  );
  const confirmedIds = useMemo(
    () => (workspace?.sentences ?? []).filter((row) => row.status === "confirmed_excluded").map((row) => row.sentence_id),
    [workspace],
  );
  const missingOnPage = useMemo(
    () =>
      pageFilter === "all"
        ? []
        : views
            .filter((item) => item.state === "missing" && item.row.page_no === pageFilter)
            .map((item) => item.row.sentence_id),
    [pageFilter, views],
  );
  const includedViews = useMemo(() => views.filter((item) => item.boundaries), [views]);

  useEffect(() => {
    activeRef.current?.scrollIntoView({ block: "nearest" });
  }, [activeIndex]);

  const refresh = async () => {
    await Promise.all([
      client.invalidateQueries(timelineWorkspaceQuery(bookId)),
      client.invalidateQueries(bookStateQuery(bookId)),
      client.invalidateQueries(originalAudioWorkspaceQuery(bookId)),
    ]);
  };

  const review = useMutation({
    mutationFn: (ids: string[]) => updateTimelineReview(bookId, Array.from(new Set(ids))),
    onSuccess: () => client.invalidateQueries(timelineWorkspaceQuery(bookId)),
  });

  const publish = useMutation({
    mutationFn: async () => {
      if (!workspace || !draft) throw new Error("校对数据尚未加载。");
      setPublishedNotice(undefined);
      setPublishJob(undefined);
      const run = await publishTimelineCorrection(bookId, toManualTable(workspace, draft));
      if (run.jobId) await waitForJob(run.jobId, setPublishJob);
    },
    onSuccess: async () => {
      setPublishedNotice("手工修正已发布。请重新导出资源包，否则分发出去的仍是旧歌词。");
      await Promise.all([
        refresh(),
        client.invalidateQueries(exportWorkspaceQuery(bookId)),
      ]);
    },
  });

  const togglePlayback = () => {
    const node = audioRef.current;
    if (!node) return;
    if (node.paused) void node.play().then(() => setPlaying(true)).catch(() => setPlaying(false));
    else {
      node.pause();
      setPlaying(false);
    }
  };
  const seek = (ms: number) => {
    const node = audioRef.current;
    if (!node) return;
    node.currentTime = ms / 1000;
    setNowMs(ms);
    nowRef.current = ms;
  };
  const playRange = (startMs: number, endMs: number) => {
    const node = audioRef.current;
    if (!node) return;
    rangeRef.current = endMs;
    node.currentTime = startMs / 1000;
    void node.play().then(() => setPlaying(true)).catch(() => setPlaying(false));
  };

  const setEntry = (row: TimelineReviewSentence, startMs: number, endMs: number) => {
    setPublishedNotice(undefined);
    setDraft((current) => {
      if (!current) return current;
      return { ...current, entries: { ...current.entries, [row.sentence_id]: { start_ms: startMs, end_ms: endMs } } };
    });
  };
  const removeEntry = (row: TimelineReviewSentence) => {
    setPublishedNotice(undefined);
    setDraft((current) => {
      if (!current) return current;
      const entries = { ...current.entries };
      delete entries[row.sentence_id];
      return { ...current, entries };
    });
  };

  const scrollToRow = (sentenceId: string) => {
    const node = document.getElementById(`lyrics-row-${sentenceId}`);
    if (!node) return;
    node.scrollIntoView({ block: "center", behavior: "smooth" });
    setFlashId(sentenceId);
    window.setTimeout(() => setFlashId((current) => (current === sentenceId ? undefined : current)), 1600);
  };

  const openEditor = (row: TimelineReviewSentence) => {
    const existing = draft?.entries[row.sentence_id];
    const position = Math.floor(nowRef.current);
    setEditing({
      row,
      startMs: existing?.start_ms ?? position,
      endMs: existing?.end_ms ?? Math.min(position + 2000, workspace?.duration_ms ?? 2000),
    });
  };
  const confirmEditor = () => {
    if (!editing) return;
    setEntry(editing.row, editing.startMs, editing.endMs);
    // Adding a previously confirmed line back means it *is* narrated.
    if (editing.row.status === "confirmed_excluded") {
      review.mutate(confirmedIds.filter((id) => id !== editing.row.sentence_id));
    }
    setEditing(undefined);
  };

  const fixByPushingStart = (issue: DraftIssue) => {
    if (!draft || !workspace || !issue.otherId || !issue.sentenceId) return;
    const other = draft.entries[issue.otherId];
    const row = workspace.sentences.find((item) => item.sentence_id === issue.sentenceId);
    const mine = draft.entries[issue.sentenceId];
    if (!other || !row || !mine) return;
    const start = other.end_ms;
    setEntry(row, start, Math.max(mine.end_ms, start + minSpanMs(row)));
  };
  const fixByShorteningOther = (issue: DraftIssue) => {
    if (!draft || !workspace || !issue.otherId || !issue.sentenceId) return;
    const otherRow = workspace.sentences.find((item) => item.sentence_id === issue.otherId);
    const other = draft.entries[issue.otherId];
    const mine = draft.entries[issue.sentenceId];
    if (!otherRow || !other || !mine) return;
    const end = mine.start_ms;
    setEntry(otherRow, Math.max(0, Math.min(other.start_ms, end - minSpanMs(otherRow))), end);
  };

  // Rebuilt only when the draft/workspace/review state changes — never on the
  // playhead tick — so memoised rows keep skipping 4 Hz re-renders.
  const rowHandlers = useMemo<RowHandlers>(
    () => ({
      onSeek: (startMs) => seek(startMs),
      onPlayRange: (startMs, endMs) => playRange(startMs, endMs),
      onEdit: (row) => openEditor(row),
      onRemove: (row) => removeEntry(row),
      onRestore: (row) => {
        if (row.start_ms != null && row.end_ms != null) setEntry(row, row.start_ms, row.end_ms);
      },
      onConfirmSkip: (row) => review.mutate([...confirmedIds, row.sentence_id]),
      onUnconfirmSkip: (row) => review.mutate(confirmedIds.filter((id) => id !== row.sentence_id)),
      onFixPush: (issue) => fixByPushingStart(issue),
      onFixShortenOther: (issue) => fixByShorteningOther(issue),
    }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [draft, workspace, confirmedIds, review],
  );

  // Neighbour context for the editing dialog, based on included sentences.
  const editingIndex = editing ? includedViews.findIndex((item) => item.row.sentence_id === editing.row.sentence_id) : -1;
  const prevIncluded = editingIndex > 0 ? includedViews[editingIndex - 1] : undefined;
  const nextIncluded = editingIndex >= 0 && editingIndex < includedViews.length - 1 ? includedViews[editingIndex + 1] : undefined;
  const editingConflict = editing
    ? [
        prevIncluded?.boundaries && editing.startMs < prevIncluded.boundaries.end_ms
          ? { otherId: prevIncluded.row.sentence_id, overlapMs: prevIncluded.boundaries.end_ms - editing.startMs }
          : null,
        nextIncluded?.boundaries && nextIncluded.boundaries.start_ms < editing.endMs
          ? { otherId: nextIncluded.row.sentence_id, overlapMs: editing.endMs - nextIncluded.boundaries.start_ms }
          : null,
      ].filter(Boolean) as Array<{ otherId: string; overlapMs: number }>
    : [];

  if (query.isPending) {
    return <div className={styles.page}><div className={styles.state}><LoaderCircle className={styles.spin} /><p>正在读取歌词校对数据…</p></div></div>;
  }
  if (query.error) {
    return <div className={styles.page}><div className={styles.state}><CircleAlert /><h1>无法读取歌词校对数据</h1><p>{query.error.message}</p></div></div>;
  }
  if (!workspace || !workspace.available) {
    return <div className={styles.page}><div className={styles.state}><ListMusic /><h1>还没有原音</h1><p>请先在语音生成页上传原音并完成分离确认。</p><Link to="/books/$bookId/audio" params={{ bookId }}>返回语音生成</Link></div></div>;
  }
  if (workspace.status === "processing") {
    return <div className={styles.page}><div className={styles.state}><LoaderCircle className={styles.spin} /><h1>正在生成逐词歌词</h1><p>自动识别原音朗读内容，完成后即可播放校对。</p></div></div>;
  }
  if (workspace.status === "not_generated") {
    return <div className={styles.page}><div className={styles.state}><ListMusic /><h1>还没有生成歌词</h1><p>{workspace.message ?? "请先在语音生成页生成逐词歌词。"}</p><Link to="/books/$bookId/audio" params={{ bookId }}>返回语音生成</Link></div></div>;
  }
  if (workspace.status === "failed") {
    return <div className={styles.page}><div className={styles.state}><CircleAlert /><h1>歌词生成失败</h1><p>{workspace.message ?? "请重新生成歌词。"}</p><Link to="/books/$bookId/audio" params={{ bookId }}>返回语音生成</Link></div></div>;
  }
  if (!draft) {
    return <div className={styles.page}><div className={styles.state}><LoaderCircle className={styles.spin} /></div></div>;
  }

  const badges = {
    missing: views.filter((item) => item.state === "missing" || item.state === "removed").length,
    matched: views.filter((item) => item.state === "included" && item.change !== "added").length,
    excluded: views.filter((item) => item.state === "excluded").length,
    changed: views.filter(
      (item) => item.change === "added" || item.change === "adjusted" || item.state === "removed",
    ).length,
    all: views.length,
  };

  return <div className={styles.page}>
    <header className={styles.header}>
      <div>
        <Link className={styles.back} to="/books/$bookId/audio" params={{ bookId }}><ArrowLeft />返回语音生成</Link>
        <h1>歌词校对</h1>
        <p>
          以校对后的绘本文本为范本逐句核对原音歌词；点句子文字可把播放跳到该句，试听确认边界。
          {workspace.whisper_model ? ` 识别模型 ${workspace.whisper_model}。` : ""}
          {workspace.alignment_strategy === "manual_correction" ? " 当前版本包含手工修正。" : ""}
        </p>
      </div>
      <div className={styles.player}>
        <button type="button" className={styles.play} onClick={togglePlayback}>{playing ? <Pause /> : <Play />}{playing ? "暂停" : "播放原音"}</button>
        <span className={styles.clock}><Clock />{formatClock(nowMs)} / {formatClock(workspace.duration_ms)}</span>
        <audio
          ref={audioRef}
          src={originalAudioSourceUrl(bookId)}
          preload="metadata"
          onTimeUpdate={(event) => {
            const node = event.currentTarget;
            const current = node.currentTime * 1000;
            setNowMs(current);
            nowRef.current = current;
            if (rangeRef.current != null && current >= rangeRef.current) {
              rangeRef.current = undefined;
              node.pause();
              setPlaying(false);
            }
          }}
          onEnded={() => setPlaying(false)}
          onPlay={() => setPlaying(true)}
          onPause={() => setPlaying(false)}
        />
      </div>
    </header>

    {workspace.status === "stale" && (
      <div className={styles.warning} role="status"><CircleAlert />{workspace.message ?? "歌词基于旧版本生成，重新生成后修改才会生效。"}</div>
    )}
    {publishedNotice && (
      <div className={styles.notice} role="status"><Check />{publishedNotice}</div>
    )}
    {(review.error || publish.error) && (
      <div className={styles.error} role="alert"><CircleAlert />{review.error?.message ?? publish.error?.message}</div>
    )}
    {publish.isPending && (
      <div className={styles.progress} role="status" aria-live="polite">
        <LoaderCircle className={styles.spin} />
        <div><strong>{publishJob?.message ?? "正在发布手工修正…"}</strong></div>
        <b>{Math.round((publishJob?.progress ?? 0) * 100)}%</b>
      </div>
    )}

    <div className={styles.toolbar}>
      <div className={styles.chips} role="tablist" aria-label="句子筛选">
        {FILTERS.map((item) => (
          <button
            key={item.id}
            type="button"
            role="tab"
            aria-selected={filter === item.id}
            data-active={filter === item.id}
            onClick={() => setFilter(item.id)}
          >
            {item.label}<i>{badges[item.id]}</i>
          </button>
        ))}
      </div>
      <div className={styles.pageTools}>
        <label>
          <span>页面</span>
          <select value={pageFilter} onChange={(event) => setPageFilter(event.target.value === "all" ? "all" : Number(event.target.value))}>
            <option value="all">全部页面</option>
            {pages.map((page) => <option key={page} value={page}>第 {page} 页</option>)}
          </select>
        </label>
        <button
          type="button"
          disabled={pageFilter === "all" || !missingOnPage.length || review.isPending}
          onClick={() => review.mutate([...confirmedIds, ...missingOnPage])}
          title="把本页所有疑似缺失句子标记为原音不朗读（适合词汇表、版权页等整页不读的文字）"
        >
          <EyeOff />本页全部不朗读（{missingOnPage.length}）
        </button>
      </div>
    </div>

    <main className={styles.list} aria-label="歌词句子">
      {visible.map((item) => (
        <SentenceRow
          key={item.row.sentence_id}
          rowRef={views[activeIndex] === item ? activeRef : undefined}
          view={item}
          issue={issuesByRow.get(item.row.sentence_id)}
          active={views[activeIndex] === item}
          flash={flashId === item.row.sentence_id}
          canShortenOther={Boolean(
            issuesByRow.get(item.row.sentence_id)?.otherId &&
              draft?.entries[issuesByRow.get(item.row.sentence_id)!.otherId!],
          )}
          busy={review.isPending}
          handlers={rowHandlers}
        />
      ))}
      {!visible.length && <div className={styles.empty}>当前筛选没有句子。</div>}
    </main>

    <footer className={styles.footer}>
      <div className={styles.footerInfo}>
        <span>已匹配 {badges.matched} · 疑似缺失 {badges.missing} · 不朗读 {badges.excluded}{dirty ? " · 有未发布修改" : ""}</span>
        {issues.length > 0 && dirty && (
          <ul className={styles.blockers}>
            {issues.slice(0, 3).map((issue, index) => (
              <li key={index}>
                {issue.sentenceId ? (
                  <button type="button" className={styles.blockerLink} onClick={() => issue.sentenceId && scrollToRow(issue.sentenceId)} title="点击定位到该句">
                    <CircleAlert />{issue.message}
                  </button>
                ) : (
                  <span><CircleAlert />{issue.message}</span>
                )}
              </li>
            ))}
            {issues.length > 3 && <li>…还有 {issues.length - 3} 个问题</li>}
          </ul>
        )}
      </div>
      <div className={styles.footerActions}>
        {overlapCount > 0 && (
          <button
            type="button"
            disabled={publish.isPending}
            title="把交叉的句子边界在两句之间平分，各自移动不超过重叠长度的一半"
            onClick={() => {
              if (!workspace || !draft) return;
              const fixed = autoFixOverlaps(workspace, draft);
              if (fixed) setDraft(fixed);
            }}
          >
            <Wand2 />自动修正重叠（{overlapCount}）
          </button>
        )}
        <button type="button" disabled={!dirty || publish.isPending} onClick={() => workspace && setDraft(buildDraft(workspace))}><RotateCcw />放弃修改</button>
        <button
          type="button"
          className={styles.publish}
          disabled={!dirty || issues.length > 0 || publish.isPending || review.isPending}
          onClick={() => publish.mutate()}
        >
          {publish.isPending ? <LoaderCircle className={styles.spin} /> : <Check />}
          发布手工修正
        </button>
      </div>
    </footer>

    {editing && (
      <div className={styles.modalOverlay} role="presentation" onClick={(event) => { if (event.target === event.currentTarget) setEditing(undefined); }}>
        <div className={styles.modal} role="dialog" aria-modal="true" aria-label="手工标记句子时间">
          <header>
            <div>
              <small>{editing.row.sentence_id} · 第 {editing.row.page_no} 页</small>
              <h2>{editing.row.text}</h2>
            </div>
            <button type="button" aria-label="关闭" onClick={() => setEditing(undefined)}>×</button>
          </header>
          <div className={styles.editors}>
            {(["startMs", "endMs"] as const).map((key) => (
              <div key={key} className={styles.editor}>
                <span>{key === "startMs" ? "起点" : "终点"} · 约 {formatClock(editing[key])}</span>
                <TimeInput valueMs={editing[key]} onCommit={(ms) => setEditing((current) => current && { ...current, [key]: ms })} />
                <div className={styles.steps}>
                  <button type="button" onClick={() => setEditing((current) => current && { ...current, [key]: Math.max(0, current[key] - 500) })}>−0.5s</button>
                  <button type="button" onClick={() => setEditing((current) => current && { ...current, [key]: Math.max(0, current[key] - 100) })}>−0.1s</button>
                  <button type="button" onClick={() => setEditing((current) => current && { ...current, [key]: current[key] + 100 })}>+0.1s</button>
                  <button type="button" onClick={() => setEditing((current) => current && { ...current, [key]: current[key] + 500 })}>+0.5s</button>
                </div>
                <button type="button" className={styles.mark} onClick={() => setEditing((current) => current && { ...current, [key]: Math.floor(nowMs) })}>
                  <Clock />用当前播放位置（{formatClock(Math.floor(nowMs))}）
                </button>
              </div>
            ))}
          </div>          {(prevIncluded || nextIncluded) && (
            <div className={styles.neighbors}>
              {prevIncluded?.boundaries && (
                <div>
                  <span>上一句 {prevIncluded.row.sentence_id}：{formatClock(prevIncluded.boundaries.start_ms)} – {formatClock(prevIncluded.boundaries.end_ms)}</span>
                  <button type="button" onClick={() => setEditing((current) => current && { ...current, startMs: prevIncluded.boundaries!.end_ms + 100 })}>起点 = 其终点 +0.1s</button>
                </div>
              )}
              {nextIncluded?.boundaries && (
                <div>
                  <span>下一句 {nextIncluded.row.sentence_id}：{formatClock(nextIncluded.boundaries.start_ms)} 开始</span>
                  <button type="button" onClick={() => setEditing((current) => current && { ...current, endMs: Math.max(current.startMs + 100, nextIncluded.boundaries!.start_ms - 100) })}>终点 = 其起点 −0.1s</button>
                </div>
              )}
            </div>
          )}
          {editingConflict.length > 0 && (
            <p className={styles.modalConflict} role="status">
              <CircleAlert />
              {editingConflict.map((conflict, index) => (
                <span key={index}>与 {conflict.otherId} 重叠 {(conflict.overlapMs / 1000).toFixed(1)} 秒；</span>
              ))}
              可用上方的「起点 = 其终点」或「终点 = 其起点」快速对齐。
            </p>
          )}
          <p className={styles.modalHint}>播放原音，在句子开始时点「用当前播放位置」设起点，读完整句后设终点；词级高亮会按词长自动分配。输入框可直接键入秒数（如 107.9），回车确认。</p>
          <footer>
            <button type="button" onClick={() => playRange(editing.startMs, editing.endMs)}><Play />试听标记区间</button>
            <button type="button" onClick={() => setEditing(undefined)}>取消</button>
            <button type="button" className={styles.publish} disabled={editing.endMs <= editing.startMs} onClick={confirmEditor}>确定</button>
          </footer>
        </div>
      </div>
    )}
  </div>;
}
