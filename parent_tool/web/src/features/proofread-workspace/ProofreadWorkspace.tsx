import { DndContext, KeyboardSensor, PointerSensor, closestCenter, useSensor, useSensors, type DragEndEvent } from "@dnd-kit/core";
import { SortableContext, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useNavigate, useParams } from "@tanstack/react-router";
import { Check, CheckCheck, CircleAlert, Combine, GripVertical, LoaderCircle, MousePointer2, PenLine, Plus, Save, Scissors, Trash2 } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { checkProofreadText, pageAssetUrl, publishProofread, type ApiRequestError, type OcrSentence } from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { bookStateQuery, proofreadWorkspaceQuery } from "../../api/queries";
import { clampBox, renumber, splitText, unionBoxes } from "./draft";
import { ProofreadStage } from "./ProofreadStage";
import styles from "./ProofreadWorkspace.module.css";

type Tool = "select" | "draw" | "split";

function SortableSentence({ sentence, active, onSelect }: { sentence: OcrSentence; active: boolean; onSelect: (additive: boolean) => void }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: sentence.id });
  return <article
    ref={setNodeRef}
    className={styles.sentence}
    data-active={active || undefined}
    data-review={sentence.status === "needs_review" || undefined}
    style={{ transform: CSS.Transform.toString(transform), transition, opacity: isDragging ? 0.45 : 1 }}
    onClick={(event) => onSelect(event.shiftKey || event.ctrlKey || event.metaKey)}
  >
    <button type="button" className={styles.dragHandle} aria-label={`拖动第 ${sentence.seq} 句排序`} {...attributes} {...listeners}><GripVertical /></button>
    <span className={styles.sequence}>{sentence.seq}</span>
    <div><p>{sentence.text}</p><small>第 {sentence.page_no} 页 {sentence.status === "needs_review" ? "· 待确认" : ""}</small></div>
  </article>;
}

function statusLabel(sentence: OcrSentence) {
  if (sentence.status === "needs_review") return "待确认";
  if (sentence.suspect_words.some((word) => word.kind === "spelling")) return "拼写提示";
  return "已识别";
}

export function ProofreadWorkspace() {
  const { bookId } = useParams({ strict: false }) as { bookId: string };
  const navigate = useNavigate();
  const client = useQueryClient();
  const workspaceQuery = useQuery(proofreadWorkspaceQuery(bookId));
  const [sentences, setSentences] = useState<OcrSentence[]>([]);
  const [confirmedPages, setConfirmedPages] = useState<number[]>([]);
  const [selectedPage, setSelectedPage] = useState(1);
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const [tool, setTool] = useState<Tool>("select");
  const [dirty, setDirty] = useState(false);
  const [jobProgress, setJobProgress] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);
  const workspace = workspaceQuery.data;
  const sensors = useSensors(useSensor(PointerSensor, { activationConstraint: { distance: 6 } }), useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }));

  useEffect(() => {
    if (!workspace) return;
    setSentences(workspace.sentences);
    setConfirmedPages(workspace.confirmed_pages);
    setSelectedPage(workspace.pages[0]?.page_no ?? 1);
    setSelectedIds([]);
    setDirty(false);
  }, [workspace?.ocr_revision_id, workspace?.proofread_revision_id]); // eslint-disable-line react-hooks/exhaustive-deps

  const page = workspace?.pages.find((item) => item.page_no === selectedPage);
  const pageSentences = useMemo(() => sentences.filter((sentence) => sentence.page_no === selectedPage), [selectedPage, sentences]);
  const selected = sentences.find((sentence) => sentence.id === selectedIds[0]);
  const pagesWithReview = useMemo(() => new Set(sentences.filter((sentence) => sentence.status === "needs_review").map((sentence) => sentence.page_no)), [sentences]);
  const virtualizer = useVirtualizer({ count: sentences.length, getScrollElement: () => listRef.current, estimateSize: () => 74, overscan: 8 });
  const allConfirmed = Boolean(workspace && workspace.pages.every((item) => confirmedPages.includes(item.page_no)));
  const canPublish = allConfirmed && !sentences.some((sentence) => sentence.status === "needs_review") && dirty;

  const replaceSentences = (next: OcrSentence[], affectedPages?: number[]) => {
    setSentences(renumber(next));
    setConfirmedPages((current) => current.filter((pageNo) => !(affectedPages?.includes(pageNo) ?? true)));
    setDirty(true);
  };
  const select = (id: string, additive = false) => setSelectedIds((current) => additive ? (current.includes(id) ? current.filter((value) => value !== id) : [...current, id]) : [id]);
  const updateSentence = (id: string, patch: Partial<OcrSentence>) => {
    const current = sentences.find((sentence) => sentence.id === id);
    if (!current) return;
    replaceSentences(sentences.map((sentence) => sentence.id === id ? { ...sentence, ...patch } : sentence), [current.page_no]);
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
      replaceSentences(updated, [source.page_no]);
      setSelectedIds([`s${String(updated.findIndex((sentence) => sentence.id === `${source.id}-split`) + 1).padStart(4, "0")}`]);
      setTool("select");
      return;
    }
    const created: OcrSentence = { id: `manual-${Date.now()}`, page_no: selectedPage, seq: sentences.length + 1, text: "请填写文本", bbox, shared_bbox: false, status: "needs_review", suspect_words: [] };
    replaceSentences([...sentences, created], [selectedPage]);
    setSelectedIds([`s${String(sentences.length + 1).padStart(4, "0")}`]);
    setTool("select");
  };
  const merge = () => {
    const selectedSentences = sentences.filter((sentence) => selectedIds.includes(sentence.id));
    if (selectedSentences.length < 2 || new Set(selectedSentences.map((sentence) => sentence.page_no)).size !== 1) return;
    const first = selectedSentences[0];
    const combined: OcrSentence = { ...first, text: selectedSentences.map((sentence) => sentence.text).join(" "), bbox: unionBoxes(selectedSentences.map((sentence) => sentence.bbox)), shared_bbox: false, status: "sentence", suspect_words: [] };
    const next = [...sentences.filter((sentence) => !selectedIds.includes(sentence.id)), combined].sort((a, b) => a.seq - b.seq);
    replaceSentences(next, [first.page_no]);
    setSelectedIds([`s${String(next.findIndex((sentence) => sentence === combined) + 1).padStart(4, "0")}`]);
  };
  const deleteSelected = () => {
    if (!selectedIds.length) return;
    const affected = sentences.filter((sentence) => selectedIds.includes(sentence.id)).map((sentence) => sentence.page_no);
    replaceSentences(sentences.filter((sentence) => !selectedIds.includes(sentence.id)), affected);
    setSelectedIds([]);
  };
  const reorder = ({ active, over }: DragEndEvent) => {
    if (!over || active.id === over.id) return;
    const from = sentences.findIndex((sentence) => sentence.id === active.id);
    const to = sentences.findIndex((sentence) => sentence.id === over.id);
    if (from < 0 || to < 0) return;
    const next = [...sentences];
    next.splice(to, 0, next.splice(from, 1)[0]);
    replaceSentences(next);
    setSelectedIds([]);
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
  const pageReady = !pagesWithReview.has(selectedPage) && !pageSentences.some((sentence) => sentence.suspect_words.some((word) => word.kind === "spelling"));

  return <section className={styles.page}>
    <header className={styles.header}>
      <div><p>工作区 / {bookId}</p><h1>OCR 与句子校对台</h1></div>
      <div className={styles.headerMeta}><span data-dirty={dirty || undefined}>{dirty ? "有未发布编辑" : workspace.proofread_revision_id ? "校对结果已发布" : "正在校对 OCR 初稿"}</span><b>{sentences.length} 句</b></div>
    </header>
    {error && <div className={styles.error} role="alert"><CircleAlert /><span>{error.message}</span></div>}
    {publish.isPending && <div className={styles.progress}><LoaderCircle className={styles.spin} /><span>正在发布校对结果</span><i style={{ transform: `scaleX(${jobProgress})` }} /></div>}

    <div className={styles.toolbar}>
      <button type="button" data-active={tool === "select" || undefined} onClick={() => setTool("select")}><MousePointer2 />选择文字框</button>
      <button type="button" data-active={tool === "draw" || undefined} onClick={() => setTool("draw")}><PenLine />手动画框</button>
      <button type="button" data-active={tool === "split" || undefined} disabled={selectedIds.length !== 1} onClick={() => setTool("split")}><Scissors />拆分并画第二框</button>
      <span />
      <button type="button" disabled={selectedIds.length < 2} onClick={merge}><Combine />合并句子</button>
      <button type="button" disabled={!selectedIds.length} onClick={deleteSelected}><Trash2 />删除</button>
    </div>

    <div className={styles.workspace}>
      <aside className={styles.thumbnails} aria-label="阅读页列表">
        <div className={styles.railHeading}><strong>阅读页</strong><span>{confirmedPages.length} / {workspace.pages.length}</span></div>
        <div className={styles.thumbnailList}>{workspace.pages.map((item) => <button type="button" key={item.page_no} data-active={item.page_no === selectedPage || undefined} onClick={() => { setSelectedPage(item.page_no); setSelectedIds([]); }}>
          <img src={pageAssetUrl(bookId, workspace.pages_revision_id, item.thumbnail)} alt="" loading="lazy" />
          <span>第 {item.page_no} 页</span><i data-confirmed={confirmedPages.includes(item.page_no) || undefined}>{confirmedPages.includes(item.page_no) ? <Check /> : pagesWithReview.has(item.page_no) ? <CircleAlert /> : <span />}</i>
        </button>)}</div>
      </aside>

      <main className={styles.canvasColumn}>
        <div className={styles.canvasHint}>{tool === "draw" ? "在阅读页上拖动，补画漏识别的句子框。" : tool === "split" ? "已选句子保留为第一框；在页面上拖动绘制第二个句子框。" : "点击文字框或句子列表可双向定位；Shift/Ctrl 点击可多选合并。"}<b>第 {selectedPage} 页</b></div>
        <ProofreadStage imageUrl={pageAssetUrl(bookId, workspace.pages_revision_id, page.image)} sentences={pageSentences} selectedIds={selectedIds} tool={tool} onSelect={select} onDraw={draw} />
      </main>

      <aside className={styles.inspector} aria-label="句子属性">
        {selected ? <>
          <div className={styles.inspectorHeading}><span>当前句子</span><strong>#{selected.seq} · 第 {selected.page_no} 页</strong></div>
          <label className={styles.textField}><span>朗读文本</span><textarea value={selected.text} onChange={(event) => updateSentence(selected.id, { text: event.target.value, status: event.target.value.trim() ? "sentence" : "needs_review", suspect_words: [] })} onBlur={(event) => { const text = event.target.value.trim(); if (text) void checkProofreadText(bookId, text).then((suspectWords) => updateSentence(selected.id, { suspect_words: suspectWords })).catch(() => undefined); }} /></label>
          <div className={styles.status}><span data-review={selected.status === "needs_review" || undefined}>{statusLabel(selected)}</span>{selected.suspect_words.map((word) => <em key={word.word} data-proper={word.kind === "proper_noun" || undefined}>{word.word}</em>)}</div>
          <section className={styles.boxEditor}><strong>文字框（归一化坐标）</strong>{(["x", "y", "width", "height"] as const).map((key) => <label key={key}><span>{{ x: "左", y: "上", width: "宽", height: "高" }[key]}</span><input type="number" min="0" max="1" step="0.001" value={selected.bbox[key]} onChange={(event) => updateSentence(selected.id, { bbox: clampBox({ ...selected.bbox, [key]: Number(event.target.value) }) })} /></label>)}</section>
        </> : <div className={styles.emptyInspector}><Plus /><strong>选择一个文字框</strong><p>可编辑文本和坐标，或切换到手动画框补录句子。</p></div>}
        <section className={styles.confirmPanel}><strong>{confirmedPages.includes(selectedPage) ? "本页已确认" : "本页等待确认"}</strong><p>{pageReady ? "没有待确认项或红色拼写提示，可以快速确认。" : "先处理待确认项与红色拼写提示，再确认本页。"}</p><button type="button" disabled={!pageReady} data-confirmed={confirmedPages.includes(selectedPage) || undefined} onClick={() => { setConfirmedPages((current) => current.includes(selectedPage) ? current.filter((pageNo) => pageNo !== selectedPage) : [...current, selectedPage].sort((a, b) => a - b)); setDirty(true); }}>{confirmedPages.includes(selectedPage) ? <Check /> : <CheckCheck />}{confirmedPages.includes(selectedPage) ? "取消确认" : "确认本页"}</button></section>
      </aside>
    </div>

    <section className={styles.listPanel}>
      <div className={styles.listHeading}><div><strong>阅读顺序</strong><span>拖动句子可调整跨页阅读 seq；排序会要求重新确认页面。</span></div><b>{sentences.length} 句</b></div>
      <div ref={listRef} className={styles.sentenceList}>
        <div style={{ height: `${virtualizer.getTotalSize()}px`, position: "relative" }}>
          <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={reorder}><SortableContext items={sentences.map((sentence) => sentence.id)} strategy={verticalListSortingStrategy}>
            {virtualizer.getVirtualItems().map((row) => { const sentence = sentences[row.index]; return <div key={sentence.id} style={{ position: "absolute", top: 0, left: 0, width: "100%", transform: `translateY(${row.start}px)` }}><SortableSentence sentence={sentence} active={selectedIds.includes(sentence.id)} onSelect={(additive) => { setSelectedPage(sentence.page_no); select(sentence.id, additive); }} /></div>; })}
          </SortableContext></DndContext>
        </div>
      </div>
    </section>

    <footer className={styles.footer}>
      <div><CheckCheck />已确认 {confirmedPages.length} / {workspace.pages.length}{!allConfirmed && <button type="button" disabled={sentences.some((sentence) => sentence.status === "needs_review" || sentence.suspect_words.some((word) => word.kind === "spelling"))} onClick={() => { setConfirmedPages(workspace.pages.map((item) => item.page_no)); setDirty(true); }}>全部确认</button>}</div>
      <div><button type="button" className={styles.publish} disabled={!canPublish || publish.isPending} onClick={() => publish.mutate()}><Save />{publish.isPending ? "正在发布" : "发布校对结果"}</button><button type="button" disabled={dirty || !allConfirmed || !workspace.proofread_revision_id} onClick={() => void navigate({ to: "/books/$bookId/audio", params: { bookId } })}>进入语音生成</button></div>
    </footer>
  </section>;
}
