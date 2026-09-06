import { DndContext, KeyboardSensor, PointerSensor, closestCenter, useSensor, useSensors, type DragEndEvent } from "@dnd-kit/core";
import { SortableContext, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useNavigate, useParams } from "@tanstack/react-router";
import { Check, CheckCheck, CircleAlert, Combine, GripVertical, Hand, ListOrdered, LoaderCircle, MousePointer2, PenLine, Plus, Save, Scissors, Trash2, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from "react";

import { checkProofreadText, pageAssetUrl, publishProofread, type ApiRequestError, type OcrSentence } from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { bookStateQuery, proofreadWorkspaceQuery } from "../../api/queries";
import { clampBox, mergeSentences, renumber, splitText } from "./draft";
import { ProofreadStage } from "./ProofreadStage";
import styles from "./ProofreadWorkspace.module.css";

type Tool = "select" | "pan" | "draw" | "split";

function SortableSentence({ sentence, active, onSelect }: { sentence: OcrSentence; active: boolean; onSelect: () => void }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: sentence.id });
  return <article
    ref={setNodeRef}
    className={styles.sentence}
    data-active={active || undefined}
    data-review={sentence.status === "needs_review" || spellingWords(sentence).length > 0 || undefined}
    style={{ transform: CSS.Transform.toString(transform), transition, opacity: isDragging ? 0.45 : 1 }}
    onClick={onSelect}
  >
    <button type="button" className={styles.dragHandle} aria-label={`拖动第 ${sentence.seq} 句排序`} {...attributes} {...listeners}><GripVertical /></button>
    <span className={styles.sequence}>{sentence.seq}</span>
    <div><p>{sentence.text}</p><small>第 {sentence.page_no} 页 · {blockerReason(sentence) === "需要处理" ? "已识别" : blockerReason(sentence)}</small></div>
  </article>;
}

function statusLabel(sentence: OcrSentence) {
  if (sentence.status === "needs_review") return "待确认";
  if (sentence.suspect_words.some((word) => word.kind === "spelling")) return "拼写提示";
  return "已识别";
}

function spellingWords(sentence: OcrSentence) {
  return sentence.suspect_words.filter((word) => word.kind === "spelling");
}

function blockerReason(sentence: OcrSentence, pendingId?: string) {
  if (sentence.id === pendingId) return sentence.text.trim() ? "待完成文字框" : "待填写文本和文字框";
  if (sentence.status === "needs_review") return sentence.text.trim() ? "需要编辑确认" : "待填写文本";
  const words = spellingWords(sentence).map((word) => word.word).join("、");
  return words ? `拼写提示：${words}` : "需要处理";
}

export function ProofreadWorkspace() {
  const { bookId } = useParams({ strict: false }) as { bookId: string };
  const navigate = useNavigate();
  const client = useQueryClient();
  const workspaceQuery = useQuery(proofreadWorkspaceQuery(bookId));
  const [sentences, setSentences] = useState<OcrSentence[]>([]);
  const [confirmedPages, setConfirmedPages] = useState<number[]>([]);
  const [selectedPage, setSelectedPage] = useState(1);
  const [selectedId, setSelectedId] = useState<string>();
  const [mergeIds, setMergeIds] = useState<string[]>([]);
  const [tool, setTool] = useState<Tool>("select");
  const [showOrder, setShowOrder] = useState(false);
  const [orderPanelHeight, setOrderPanelHeight] = useState<number>();
  const [dirty, setDirty] = useState(false);
  const [jobProgress, setJobProgress] = useState(0);
  const [newlyAddedId, setNewlyAddedId] = useState<string>();
  const [pendingBoxId, setPendingBoxId] = useState<string>();
  const listRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const workspace = workspaceQuery.data;
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }), useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }));

  useEffect(() => {
    if (!workspace) return;
    setSentences(workspace.sentences);
    setConfirmedPages(workspace.confirmed_pages);
    setSelectedPage(workspace.pages[0]?.page_no ?? 1);
    setSelectedId(undefined);
    setMergeIds([]);
    setNewlyAddedId(undefined);
    setPendingBoxId(undefined);
    setDirty(false);
  }, [workspace?.ocr_revision_id, workspace?.proofread_revision_id]); // eslint-disable-line react-hooks/exhaustive-deps

  const page = workspace?.pages.find((item) => item.page_no === selectedPage);
  const pageSentences = useMemo(() => sentences.filter((sentence) => sentence.page_no === selectedPage), [selectedPage, sentences]);
  const selected = sentences.find((sentence) => sentence.id === selectedId);
  const selectedMergeSentences = useMemo(() => sentences.filter((sentence) => mergeIds.includes(sentence.id)), [sentences, mergeIds]);
  const canMerge = selectedMergeSentences.length >= 2 && new Set(selectedMergeSentences.map((sentence) => sentence.page_no)).size === 1;
  const mergeHint = mergeIds.length === 0 ? "点击句子编辑；需要合并时，勾选 2 句或更多" : canMerge ? `已选 ${mergeIds.length} 句，可以合并` : "请在本页勾选至少 2 句";
  const sharedBoxSentences = useMemo(() => {
    if (!selected?.shared_bbox) return [];
    return pageSentences.filter((sentence) =>
      sentence.shared_bbox
      && sentence.bbox.x === selected.bbox.x
      && sentence.bbox.y === selected.bbox.y
      && sentence.bbox.width === selected.bbox.width
      && sentence.bbox.height === selected.bbox.height,
    );
  }, [pageSentences, selected]);
  const pagesWithReview = useMemo(() => new Set(sentences.filter((sentence) => sentence.status === "needs_review" || sentence.id === pendingBoxId || spellingWords(sentence).length > 0).map((sentence) => sentence.page_no)), [pendingBoxId, sentences]);
  const confirmationBlockers = useMemo(
    () => sentences.filter((sentence) => sentence.status === "needs_review" || sentence.id === pendingBoxId || spellingWords(sentence).length > 0),
    [pendingBoxId, sentences],
  );
  const currentPageBlockers = useMemo(() => confirmationBlockers.filter((sentence) => sentence.page_no === selectedPage), [confirmationBlockers, selectedPage]);
  const virtualizer = useVirtualizer({ count: sentences.length, getScrollElement: () => listRef.current, estimateSize: () => 60, overscan: 10 });
  const allConfirmed = Boolean(workspace && workspace.pages.every((item) => confirmedPages.includes(item.page_no)));
  const canPublish = allConfirmed && confirmationBlockers.length === 0 && dirty;

  useEffect(() => {
    if (!newlyAddedId || selectedId !== newlyAddedId) return undefined;
    const frame = window.requestAnimationFrame(() => textareaRef.current?.focus());
    return () => window.cancelAnimationFrame(frame);
  }, [newlyAddedId, selectedId]);

  const replaceSentences = (next: OcrSentence[], affectedPages?: number[], focusIndex?: number) => {
    const pendingIndex = pendingBoxId ? next.findIndex((sentence) => sentence.id === pendingBoxId) : -1;
    const newlyAddedIndex = newlyAddedId ? next.findIndex((sentence) => sentence.id === newlyAddedId) : -1;
    const normalized = renumber(next);
    setSentences(normalized);
    setConfirmedPages((current) => current.filter((pageNo) => !(affectedPages?.includes(pageNo) ?? true)));
    setMergeIds([]);
    if (pendingBoxId) setPendingBoxId(pendingIndex >= 0 ? normalized[pendingIndex]?.id : undefined);
    if (newlyAddedId) setNewlyAddedId(newlyAddedIndex >= 0 ? normalized[newlyAddedIndex]?.id : undefined);
    if (focusIndex !== undefined) setSelectedId(normalized[focusIndex]?.id);
    setDirty(true);
    return normalized;
  };
  const resizeOrderPanel = (event: ReactPointerEvent<HTMLDivElement>) => {
    event.preventDefault();
    const startY = event.clientY;
    const startHeight = event.currentTarget.parentElement?.getBoundingClientRect().height ?? 420;
    const move = (next: PointerEvent) => {
      const maximum = Math.max(300, window.innerHeight - 190);
      setOrderPanelHeight(Math.max(240, Math.min(maximum, startHeight + startY - next.clientY)));
    };
    const end = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", end);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", end, { once: true });
  };
  const select = (id: string) => {
    setSelectedId(id);
    setMergeIds([]);
    setNewlyAddedId(undefined);
  };
  const toggleMerge = (id: string) => setMergeIds((current) => current.includes(id) ? current.filter((value) => value !== id) : [...current, id]);
  const beginManualSentence = () => {
    const pending = pendingBoxId ? sentences.find((sentence) => sentence.id === pendingBoxId) : undefined;
    if (pending && pending.page_no === selectedPage) {
      setSelectedId(pending.id);
      setNewlyAddedId(pending.id);
      setTool("draw");
      return;
    }
    if (pendingBoxId) setPendingBoxId(undefined);
    const created: OcrSentence = {
      id: `manual-${Date.now()}`,
      page_no: selectedPage,
      seq: sentences.length + 1,
      text: "",
      bbox: { x: 0, y: 0, width: 0.01, height: 0.01 },
      shared_bbox: false,
      status: "needs_review",
      suspect_words: [],
    };
    const normalized = replaceSentences([...sentences, created], [selectedPage], sentences.length);
    const id = normalized[sentences.length]?.id;
    setSelectedId(id);
    setNewlyAddedId(id);
    setPendingBoxId(id);
    setTool("draw");
  };
  const toggleContinuousRecording = () => {
    if (tool === "draw") {
      setTool("select");
      return;
    }
    beginManualSentence();
  };
  const updateSentence = (id: string, patch: Partial<OcrSentence>) => {
    const current = sentences.find((sentence) => sentence.id === id);
    if (!current) return;
    const index = sentences.findIndex((sentence) => sentence.id === id);
    replaceSentences(sentences.map((sentence) => sentence.id === id ? { ...sentence, ...patch } : sentence), [current.page_no], index);
  };
  const focusBlocker = (sentence: OcrSentence) => {
    setSelectedPage(sentence.page_no);
    select(sentence.id);
    if (sentence.id === pendingBoxId) {
      setNewlyAddedId(sentence.id);
      setTool("draw");
    } else {
      setTool("select");
    }
  };
  const confirmSpelling = (sentence: OcrSentence) => {
    if (!spellingWords(sentence).length) return;
    updateSentence(sentence.id, { suspect_words: [] });
  };
  const draw = (bbox: OcrSentence["bbox"], splitSourceId?: string) => {
    if (splitSourceId) {
      const source = sentences.find((sentence) => sentence.id === splitSourceId);
      if (!source) return;
      const [first, second] = splitText(source.text);
      const updated = sentences.flatMap((sentence) => sentence.id === source.id ? [
        { ...sentence, text: first, shared_bbox: false, status: "sentence" as const },
        { ...sentence, id: `${sentence.id}-split`, text: second, bbox, shared_bbox: false, status: "needs_review" as const, suspect_words: [] },
      ] : [sentence]);
      const splitIndex = updated.findIndex((sentence) => sentence.id === `${source.id}-split`);
      replaceSentences(updated, [source.page_no], splitIndex);
      setTool("select");
      return;
    }
    if (pendingBoxId && selectedId === pendingBoxId) {
      updateSentence(pendingBoxId, { bbox });
      setPendingBoxId(undefined);
      return;
    }
    const created: OcrSentence = { id: `manual-${Date.now()}`, page_no: selectedPage, seq: sentences.length + 1, text: "", bbox, shared_bbox: false, status: "needs_review", suspect_words: [] };
    const normalized = replaceSentences([...sentences, created], [selectedPage], sentences.length);
    setNewlyAddedId(normalized[sentences.length]?.id);
  };
  const merge = () => {
    if (!canMerge) return;
    const affectedPages = [...new Set(selectedMergeSentences.map((sentence) => sentence.page_no))];
    const next = mergeSentences(sentences, mergeIds);
    const mergedIndex = next.findIndex((sentence) => sentence.id === selectedMergeSentences[0].id);
    replaceSentences(next, affectedPages, mergedIndex);
    setNewlyAddedId(undefined);
  };
  const deleteSelected = () => {
    if (!selectedId) return;
    const target = sentences.find((sentence) => sentence.id === selectedId);
    if (!target) return;
    replaceSentences(sentences.filter((sentence) => sentence.id !== selectedId), [target.page_no]);
    setSelectedId(undefined);
    setNewlyAddedId(undefined);
  };
  const reorder = ({ active, over }: DragEndEvent) => {
    if (!over || active.id === over.id) return;
    const from = sentences.findIndex((sentence) => sentence.id === active.id);
    const to = sentences.findIndex((sentence) => sentence.id === over.id);
    if (from < 0 || to < 0) return;
    const next = [...sentences];
    next.splice(to, 0, next.splice(from, 1)[0]);
    const focusIndex = selectedId ? next.findIndex((sentence) => sentence.id === selectedId) : undefined;
    replaceSentences(next, undefined, focusIndex === undefined || focusIndex < 0 ? undefined : focusIndex);
  };

  const publish = useMutation({
    mutationFn: async () => {
      if (!workspace) return;
      setJobProgress(0);
      const run = await publishProofread(bookId, { source_ocr_revision: workspace.ocr_revision_id, sentences, confirmed_pages: confirmedPages });
      if (run.jobId) await waitForJob(run.jobId, (snapshot) => setJobProgress(snapshot.progress));
    },
    onSuccess: async () => {
      await Promise.all([client.invalidateQueries({ queryKey: ["books", bookId, "proofread"] }), client.invalidateQueries(bookStateQuery(bookId))]);
      setDirty(false);
    },
  });

  if (workspaceQuery.isPending) return <div className={styles.state}><LoaderCircle className={styles.spin} /><p>正在展开 OCR 校对台…</p></div>;
  if (workspaceQuery.isError || !workspace || !page) {
    const error = workspaceQuery.error as ApiRequestError | null;
    return <div className={styles.state} role="alert"><CircleAlert /><h1>OCR 校对台暂时无法打开</h1><p>{error?.message ?? "请先完成页面处理与 OCR。"}</p></div>;
  }
  const error = publish.error as ApiRequestError | null;
  const pageReady = currentPageBlockers.length === 0;
  const selectedOnPage = selectedId ? pageSentences.some((sentence) => sentence.id === selectedId) : false;
  const isNewSentence = Boolean(selected && selected.id === newlyAddedId);

  return <section className={styles.page}>
    <header className={styles.header}>
      <div><p>工作区 / {bookId}</p><h1>OCR 与句子校对台</h1></div>
      <div className={styles.headerMeta}><span data-dirty={dirty || undefined}>{dirty ? "有未发布编辑" : workspace.proofread_revision_id ? "校对结果已发布" : "正在校对 OCR 初稿"}</span><b>{sentences.length} 句</b></div>
    </header>
    {error && <div className={styles.error} role="alert"><CircleAlert /><span>{error.message}</span></div>}
    {publish.isPending && <div className={styles.progress}><LoaderCircle className={styles.spin} /><span>正在发布校对结果</span><i style={{ transform: `scaleX(${jobProgress})` }} /></div>}

    <div className={styles.toolbar}>
      <button type="button" data-active={tool === "select" || undefined} onClick={() => setTool("select")}><MousePointer2 />选择文字框</button>
      <button type="button" data-active={tool === "pan" || undefined} onClick={() => setTool("pan")}><Hand />移动画布</button>
      <button type="button" data-active={tool === "draw" || undefined} onClick={toggleContinuousRecording}><PenLine />{tool === "draw" ? "结束补录" : "连续补录"}</button>
      <button type="button" data-active={tool === "split" || undefined} disabled={!selectedId} onClick={() => setTool("split")}><Scissors />拆分并画第二框</button>
      <span />
      <button type="button" data-active={showOrder || undefined} onClick={() => setShowOrder((value) => !value)}><ListOrdered />阅读顺序</button>
      <button type="button" disabled={!canMerge} onClick={merge}><Combine />合并所选句子{canMerge ? ` (${selectedMergeSentences.length})` : ""}</button>
      <button type="button" disabled={!selectedId} onClick={deleteSelected}><Trash2 />删除</button>
    </div>

    <div className={styles.workspace}>
      <aside className={styles.thumbnails} aria-label="阅读页列表">
        <div className={styles.railHeading}><strong>阅读页</strong><span>{confirmedPages.length} / {workspace.pages.length}</span></div>
        <div className={styles.thumbnailList}>{workspace.pages.map((item) => <button type="button" key={item.page_no} data-active={item.page_no === selectedPage || undefined} onClick={() => { setSelectedPage(item.page_no); setSelectedId(undefined); setMergeIds([]); setNewlyAddedId(undefined); }}>
          <img src={pageAssetUrl(bookId, workspace.pages_revision_id, item.thumbnail)} alt="" loading="lazy" />
          <span>第 {item.page_no} 页</span><i data-confirmed={confirmedPages.includes(item.page_no) || undefined}>{confirmedPages.includes(item.page_no) ? <Check /> : pagesWithReview.has(item.page_no) ? <CircleAlert /> : <span />}</i>
        </button>)}</div>
      </aside>

      <main className={styles.canvasColumn}>
        <div className={styles.canvasHint}>{tool === "draw" ? "连续补录：拖动一个框后在右侧填写文本，可继续在本页补录下一句；点击“结束补录”完成。" : pendingBoxId && selectedId === pendingBoxId ? "已结束补录：当前句子草稿已保留；点击右侧“继续框选”完成文字框。" : tool === "split" ? "已选句子保留为第一框；在页面上拖动绘制第二个句子框。" : "点击文字框或句子列表可双向定位；同一文字框内可勾选多句后合并。"}<b>第 {selectedPage} 页</b></div>
        <ProofreadStage imageUrl={pageAssetUrl(bookId, workspace.pages_revision_id, page.image)} sentences={pageSentences} selectedIds={selectedId ? [selectedId] : []} pendingSentenceId={pendingBoxId} tool={tool} onSelect={(id) => select(id)} onDraw={draw} onChangeBox={(id, bbox) => updateSentence(id, { bbox })} />
      </main>

      <aside className={styles.inspector} aria-label="句子属性">
        <section className={styles.pageSentenceList} aria-label={`第 ${selectedPage} 页句子`}>
          <div className={styles.pageSentenceListHeader}>
            <div><strong>本页句子</strong><span>{mergeHint}</span></div>
            <button type="button" disabled={!canMerge} onClick={merge}><Combine />合并{canMerge ? ` (${selectedMergeSentences.length})` : ""}</button>
          </div>
          <div className={styles.pageSentenceRows}>{pageSentences.map((sentence) => <div key={sentence.id} className={styles.pageSentenceRow} data-current={sentence.id === selectedId || undefined} data-merge={mergeIds.includes(sentence.id) || undefined}>
            <input type="checkbox" checked={mergeIds.includes(sentence.id)} disabled={sentence.id === pendingBoxId} aria-label={sentence.id === pendingBoxId ? `第 ${sentence.seq} 句待框选，暂不可合并` : `选择第 ${sentence.seq} 句用于合并`} onChange={() => toggleMerge(sentence.id)} />
            <button type="button" className={styles.pageSentenceEdit} onClick={() => select(sentence.id)}>
              <span><b>#{sentence.seq}</b><em data-review={sentence.status === "needs_review" || spellingWords(sentence).length > 0 || undefined}>{sentence.status === "needs_review" ? "待填写" : statusLabel(sentence)}</em></span>
              <p>{sentence.text || "新句子（待填写）"}</p>
            </button>
          </div>)}</div>
        </section>
        {selected ? <>
          <div className={styles.inspectorHeading}><span>当前句子</span><strong>#{selected.seq} · 第 {selected.page_no} 页</strong></div>
          {sharedBoxSentences.length > 1 && <section className={styles.sharedBoxNotice} aria-label="同一文字框内的句子">
            <strong>同一文字框内有 {sharedBoxSentences.length} 句</strong>
            <p>这些句子共用一个区域；如需合成一句，请在上方列表勾选后点击“合并”。当前句不会默认勾选。</p>
          </section>}
          {isNewSentence && <div className={styles.newSentenceNotice}><Plus /><div><strong>{pendingBoxId === selected.id ? tool === "draw" ? "正在补录这句话" : "已结束补录" : tool === "draw" ? "连续补录中" : "已添加新句子"}</strong><span>{pendingBoxId === selected.id ? tool === "draw" ? "先在下方输入文本，再在画布上拖动框选这句话。" : "当前句子草稿已保留；点击“继续框选”完成这句话，或回到顶部点击“连续补录”添加新句子。" : tool === "draw" ? "当前句已画框，可以继续在画布上框选，或添加下一句。" : "请在下方输入文本；需要补框时点击“继续框选”。"}</span>{pendingBoxId === selected.id ? <button type="button" onClick={() => setTool("draw")}><PenLine />{tool === "draw" ? "去画布框选" : "继续框选"}</button> : tool === "draw" ? <button type="button" onClick={beginManualSentence}><Plus />添加下一句</button> : null}</div></div>}
          <label className={styles.textField}><span>朗读文本</span><textarea ref={textareaRef} value={selected.text} placeholder="输入这一页要朗读的英文句子…" onChange={(event) => updateSentence(selected.id, { text: event.target.value, status: event.target.value.trim() ? "sentence" : "needs_review", suspect_words: [] })} onBlur={(event) => { const text = event.target.value.trim(); if (text) void checkProofreadText(bookId, text).then((suspectWords) => updateSentence(selected.id, { suspect_words: suspectWords })).catch(() => undefined); }} /></label>
          <div className={styles.status}><span data-review={selected.status === "needs_review" || undefined}>{statusLabel(selected)}</span>{selected.suspect_words.map((word) => <em key={word.word} data-proper={word.kind === "proper_noun" || undefined}>{word.word}</em>)}</div>
          {pendingBoxId !== selected.id && <section className={styles.boxEditor}><strong>文字框（归一化坐标）</strong>{(["x", "y", "width", "height"] as const).map((key) => <label key={key}><span>{{ x: "左", y: "上", width: "宽", height: "高" }[key]}</span><input type="number" min="0" max="1" step="0.001" value={selected.bbox[key]} onChange={(event) => updateSentence(selected.id, { bbox: clampBox({ ...selected.bbox, [key]: Number(event.target.value) }) })} /></label>)}</section>}
        </> : <div className={styles.emptyInspector}><Plus /><strong>{selectedOnPage ? "选择一个文字框" : "从本页句子开始"}</strong><p>点击上方句子行进入编辑，或在当前页连续补录多句。</p><button type="button" onClick={beginManualSentence}><PenLine />在本页添加句子</button></div>}
        <section className={styles.confirmPanel}>
          <div className={styles.confirmPanelHeading}>
            <div><strong>{confirmedPages.includes(selectedPage) ? "本页已确认" : "本页等待确认"}</strong><p>{pageReady ? "没有待处理项，可以确认本页。" : `处理下面 ${currentPageBlockers.length} 句后，即可确认本页。`}</p></div>
            {!pageReady && <span className={styles.blockerCount}>{currentPageBlockers.length} 句</span>}
          </div>
          {!pageReady && <div className={styles.blockerList} aria-label="本页待处理句子">
            {currentPageBlockers.map((sentence) => {
              const words = spellingWords(sentence);
              const spellingHint = sentence.status !== "needs_review" && words.length > 0;
              return <div key={sentence.id} className={styles.blockerRow}>
                <button type="button" className={styles.blockerTarget} onClick={() => focusBlocker(sentence)}>
                  <span><b>#{sentence.seq}</b><em>{blockerReason(sentence, pendingBoxId)}</em></span>
                  <p>{sentence.text || "未填写文本"}</p>
                  <small>{spellingHint ? `发现：${words.map((word) => word.word).join("、")}` : sentence.id === pendingBoxId ? "还未完成文字框，点击打开后继续框选。" : "点击打开句子并填写或确认。"}</small>
                </button>
                {spellingHint && <button type="button" className={styles.resolveBlocker} onClick={() => confirmSpelling(sentence)}><Check />确认拼写无误</button>}
              </div>;
            })}
          </div>}
          <button type="button" title={!pageReady ? "请先处理上面的待处理句子" : undefined} disabled={!pageReady} data-confirmed={confirmedPages.includes(selectedPage) || undefined} onClick={() => { setConfirmedPages((current) => current.includes(selectedPage) ? current.filter((pageNo) => pageNo !== selectedPage) : [...current, selectedPage].sort((a, b) => a - b)); setDirty(true); }}>{confirmedPages.includes(selectedPage) ? <Check /> : <CheckCheck />}{confirmedPages.includes(selectedPage) ? "取消确认" : "确认本页"}</button>
        </section>
      </aside>
    </div>

    {showOrder && <><button type="button" className={styles.listBackdrop} aria-label="关闭阅读顺序" onClick={() => setShowOrder(false)} /><section className={styles.listPanel} style={orderPanelHeight ? ({ "--order-panel-height": `${orderPanelHeight}px` } as CSSProperties) : undefined}>
      <div className={styles.resizeHandle} role="separator" aria-label="拖动调整阅读顺序窗口高度" aria-orientation="horizontal" onPointerDown={resizeOrderPanel}><span /></div>
      <div className={styles.listHeading}><div><strong>阅读顺序</strong><span>拖动句子可调整跨页阅读 seq；拖动顶部边框可调整窗口高度。</span></div><b>{sentences.length} 句</b><button type="button" className={styles.closeOrder} aria-label="关闭阅读顺序" onClick={() => setShowOrder(false)}><X /></button></div>
      <div ref={listRef} className={styles.sentenceList}>
        <div style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative" }}>
          <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={reorder}><SortableContext items={sentences.map((sentence) => sentence.id)} strategy={verticalListSortingStrategy}>
            {virtualizer.getVirtualItems().map((row) => { const sentence = sentences[row.index]; return <div key={sentence.id} style={{ position: "absolute", top: 0, left: 0, width: "100%", transform: `translateY(${row.start}px)` }}><SortableSentence sentence={sentence} active={sentence.id === selectedId} onSelect={() => { setSelectedPage(sentence.page_no); select(sentence.id); }} /></div>; })}
          </SortableContext></DndContext>
        </div>
      </div>
    </section></>}

    <footer className={styles.footer}>
      <div className={styles.confirmSummary}>
        <CheckCheck /><span>已确认 {confirmedPages.length} / {workspace.pages.length}</span>
        {(!allConfirmed || confirmationBlockers.length > 0) && <div className={styles.confirmAll}>
          {!allConfirmed && <button type="button" disabled={confirmationBlockers.length > 0} title={confirmationBlockers.length ? "请先处理待处理句子" : "确认所有尚未确认的页面"} onClick={() => { setConfirmedPages(workspace.pages.map((item) => item.page_no)); setDirty(true); }}>全部确认</button>}
          {confirmationBlockers.length > 0 ? <>
            <div className={styles.pendingSummary}><CircleAlert /><strong>还有 {confirmationBlockers.length} 句需要处理</strong><span>处理后才能确认页面</span></div>
            <div className={styles.pendingBlockers} aria-label="全部待处理句子">
              {confirmationBlockers.slice(0, 3).map((sentence) => <button type="button" key={sentence.id} onClick={() => focusBlocker(sentence)}><b>第 {sentence.page_no} 页 · #{sentence.seq}</b><small>{blockerReason(sentence, pendingBoxId)}</small></button>)}
              {confirmationBlockers.length > 3 && <span>还有 {confirmationBlockers.length - 3} 句</span>}
            </div>
          </> : <span data-ready>所有页面已无待处理项，可一键确认</span>}
        </div>}
      </div>
      <div><button type="button" className={styles.publish} disabled={!canPublish || publish.isPending} onClick={() => publish.mutate()}><Save />{publish.isPending ? "正在发布" : "发布校对结果"}</button><button type="button" disabled={dirty || !allConfirmed || !workspace.proofread_revision_id} onClick={() => void navigate({ to: "/books/$bookId/audio", params: { bookId } })}>进入语音生成</button></div>
    </footer>
  </section>;
}
