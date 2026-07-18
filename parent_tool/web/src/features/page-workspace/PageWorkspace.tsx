import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useParams } from "@tanstack/react-router";
import {
  Check,
  CheckCheck,
  ChevronRight,
  CircleAlert,
  Columns2,
  Crop,
  Hand,
  Image as ImageIcon,
  LoaderCircle,
  Maximize2,
  RotateCw,
  Save,
  ScanText,
  Square,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import {
  pageAssetUrl,
  runOcr,
  runPageProcessing,
  sourcePagePreviewUrl,
  type ApiRequestError,
  type JobSnapshot,
  type PageDecision,
  type PageRunParams,
} from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { bookStateQuery, pageWorkspaceQuery } from "../../api/queries";
import { PageStage } from "../../canvas/PageStage";
import { clamp } from "../../canvas/geometry";
import { usePageWorkspaceStore, type PageTool } from "../../stores/pageWorkspaceStore";
import styles from "./PageWorkspace.module.css";

const tools: Array<{ tool: PageTool; label: string; icon: typeof Hand }> = [
  { tool: "pan", label: "移动画布", icon: Hand },
  { tool: "split", label: "调整拆分线", icon: Columns2 },
  { tool: "crop", label: "查看裁边", icon: Crop },
];

function nextRotation(current: PageDecision["rotate"]): PageDecision["rotate"] {
  return ((current + 90) % 360) as PageDecision["rotate"];
}

function decisionChanged(current: PageDecision, saved: PageDecision): boolean {
  return JSON.stringify(current) !== JSON.stringify(saved);
}

function toolHint(tool: PageTool, mode: PageDecision["mode"]): string {
  if (tool === "pan") return "拖动画布查看细节；滚轮或下方按钮可缩放。";
  if (tool === "crop") return "裁边框显示最终保留范围；可在右侧输入精确百分比。";
  if (tool === "split" && mode === "split_lr") return "拖动青色分割线，或在右侧输入左右比例。";
  if (tool === "split") return "先选择“左右拆分”，再调整分割线。";
  return "文字框来自当前有效 OCR；页面决策改变后将暂时隐藏，重新 OCR 后恢复。";
}

function ProgressStrip({ job, label }: { job: JobSnapshot; label: string }) {
  const percentage = Math.round(job.progress * 100);
  return (
    <div className={styles.progressStrip} role="status" aria-live="polite">
      <LoaderCircle className={styles.spin} />
      <strong>{job.message}</strong>
      <span>{percentage}%</span>
      <div role="progressbar" aria-label={`${label}进度`} aria-valuenow={percentage}>
        <i style={{ transform: `scaleX(${job.progress})` }} />
      </div>
    </div>
  );
}

export function PageWorkspace() {
  const { bookId } = useParams({ strict: false }) as { bookId: string };
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const workspaceQuery = useQuery(pageWorkspaceQuery(bookId));
  const stateQuery = useQuery(bookStateQuery(bookId));
  const [job, setJob] = useState<JobSnapshot>();
  const [jobLabel, setJobLabel] = useState("重建页面");
  const [confirming, setConfirming] = useState(false);
  const store = usePageWorkspaceStore();
  const workspace = workspaceQuery.data;

  useEffect(() => {
    if (workspace) store.hydrate(workspace.plan.pages);
  }, [workspace?.revision_id]); // eslint-disable-line react-hooks/exhaustive-deps

  const entry = workspace?.plan.pages.find(
    (item) => item.source_pdf_page === store.selectedSourcePage,
  );
  const decision = entry ? (store.decisions[entry.source_pdf_page] ?? entry.decision) : undefined;
  const currentChanged = Boolean(entry && decision && decisionChanged(decision, entry.decision));
  const unconfirmedCount = workspace
    ? workspace.plan.pages.filter((item) => !(store.decisions[item.source_pdf_page] ?? item.decision).confirmed).length
    : 0;
  const downstreamHasSuccess = useMemo(() => {
    const steps = stateQuery.data?.steps;
    return steps ? [steps.ocr, steps.proofread, steps.audio, steps.export].some((step) => step.success) : false;
  }, [stateQuery.data]);

  const mutation = useMutation({
    mutationFn: async () => {
      if (!workspace) return;
      setJobLabel("重建页面");
      setJob(undefined);
      const params = {
        ...workspace.plan.params,
        page_decisions: workspace.plan.pages.map((item) => ({
          source_pdf_page: item.source_pdf_page,
          decision: store.decisions[item.source_pdf_page] ?? item.decision,
        })),
      } satisfies PageRunParams;
      const run = await runPageProcessing(bookId, params);
      if (run.jobId) await waitForJob(run.jobId, setJob);
    },
    onSuccess: async () => {
      setConfirming(false);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["books", bookId, "state"] }),
        queryClient.invalidateQueries({ queryKey: ["books", bookId, "pages", "workspace"] }),
      ]);
    },
  });

  const ocrMutation = useMutation({
    mutationFn: async () => {
      setJobLabel("OCR 识别");
      setJob(undefined);
      const run = await runOcr(bookId);
      if (run.jobId) await waitForJob(run.jobId, setJob);
    },
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["books", bookId, "state"] }),
        queryClient.invalidateQueries({ queryKey: ["books", bookId, "proofread", "workspace"] }),
      ]);
      await navigate({ to: "/books/$bookId/proofread", params: { bookId } });
    },
  });

  if (workspaceQuery.isPending) {
    return <div className={styles.statePage}><LoaderCircle className={styles.spin} /><p>正在展开页面工作区…</p></div>;
  }
  if (workspaceQuery.isError || !workspace || !entry || !decision) {
    const error = workspaceQuery.error as ApiRequestError | null;
    return (
      <div className={styles.statePage} role="alert">
        <CircleAlert />
        <h1>页面工作区暂时无法打开</h1>
        <p>{error?.message ?? "请返回资源创建页重新分析 PDF。"}</p>
        <a href="/books/new">重新导入绘本</a>
      </div>
    );
  }

  const updateDecision = (next: PageDecision, confirm = false) => {
    store.updateDecision(entry.source_pdf_page, { ...next, confirmed: confirm || next.confirmed });
  };
  const editDecision = (next: PageDecision) => updateDecision({ ...next, confirmed: false });
  const error = (mutation.error ?? ocrMutation.error) as ApiRequestError | null;
  const crop = decision.crop_pct ?? { top: 0, right: 0, bottom: 0, left: 0 };
  const matchingSentences = workspace.sentences.filter((sentence) =>
    entry.outputs.some((output) => output.page_no === sentence.page_no),
  );

  return (
    <section className={styles.page}>
      <header className={styles.header}>
        <div>
          <p>工作区 / {bookId}</p>
          <h1>页面处理校对台</h1>
        </div>
        <div className={styles.headerMeta}>
          <span data-dirty={store.dirty || undefined}>{store.dirty ? "有未保存调整" : "页面决策已同步"}</span>
          <b>{workspace.plan.source_pdf_page_count} 个源页</b>
        </div>
      </header>

      {job && (mutation.isPending || ocrMutation.isPending) && <ProgressStrip job={job} label={jobLabel} />}
      {error && (
        <div className={styles.errorBanner} role="alert">
          <CircleAlert /><div><strong>{ocrMutation.isError ? "OCR 识别没有完成" : "页面没有重建完成"}</strong><p>{error.message}</p></div>
        </div>
      )}

      <div className={styles.toolbar} aria-label="页面处理工具栏">
        <div className={styles.modeGroup} role="group" aria-label="页面处理模式">
          <button
            type="button"
            aria-pressed={decision.mode === "keep"}
            data-active={decision.mode === "keep" || undefined}
            onClick={() => editDecision({ ...decision, mode: "keep", split_ratio: null })}
          ><Square />保持单页</button>
          <button
            type="button"
            aria-pressed={decision.mode === "split_lr"}
            data-active={decision.mode === "split_lr" || undefined}
            onClick={() => {
              editDecision({
                ...decision,
                mode: "split_lr",
                split_ratio: decision.split_ratio ?? entry.detect.suggested_split_ratio ?? 0.5,
              });
              store.setTool("split");
            }}
          ><Columns2 />左右拆分</button>
        </div>
        <span className={styles.toolDivider} />
        <button type="button" onClick={() => editDecision({ ...decision, rotate: nextRotation(decision.rotate) })}>
          <RotateCw />旋转 90°
        </button>
        {tools.map(({ tool, label, icon: Icon }) => (
          <button
            type="button"
            key={tool}
            aria-pressed={store.tool === tool}
            data-active={store.tool === tool || undefined}
            onClick={() => store.setTool(tool)}
          ><Icon />{label}</button>
        ))}
        <button
          type="button"
          aria-pressed={store.showBboxes}
          data-active={store.showBboxes || undefined}
          onClick={store.toggleBboxes}
        ><ScanText />文字框</button>
      </div>

      <div className={styles.workspace}>
        <aside className={styles.thumbnails} aria-label="源 PDF 页面">
          <div className={styles.railHeading}>
            <strong>页面</strong><span>{store.selectedSourcePage} / {workspace.plan.source_pdf_page_count}</span>
          </div>
          <div className={styles.thumbnailList}>
            {workspace.plan.pages.map((item) => {
              const itemDecision = store.decisions[item.source_pdf_page] ?? item.decision;
              const thumbnail = item.outputs[0]?.thumbnail;
              return (
                <button
                  type="button"
                  key={item.source_pdf_page}
                  data-active={item.source_pdf_page === store.selectedSourcePage || undefined}
                  onClick={() => store.selectPage(item.source_pdf_page)}
                  aria-label={`源 PDF 第 ${item.source_pdf_page} 页，${itemDecision.confirmed ? "已确认" : "待确认"}`}
                >
                  {thumbnail ? (
                    <img
                      src={pageAssetUrl(bookId, workspace.revision_id, thumbnail)}
                      alt=""
                      loading="lazy"
                    />
                  ) : <ImageIcon />}
                  <span>p{String(item.source_pdf_page).padStart(4, "0")}</span>
                  <i data-confirmed={itemDecision.confirmed || undefined}>
                    {itemDecision.confirmed ? <Check /> : <CircleAlert />}
                  </i>
                  {itemDecision.mode === "split_lr" && <b>2 页</b>}
                </button>
              );
            })}
          </div>
        </aside>

        <main className={styles.canvasColumn}>
          <div className={styles.canvasHint}>
            <span><CircleAlert />{toolHint(store.tool, decision.mode)}</span>
            <b>源 PDF 第 {entry.source_pdf_page} 页</b>
          </div>
          {currentChanged && workspace.sentences.length > 0 && (
            <div className={styles.staleOverlayNotice}>
              页面几何已改变，旧文字框暂时隐藏；保存后需重新运行 OCR。
            </div>
          )}
          <div className={styles.canvasFrame}>
            <PageStage
              imageUrl={sourcePagePreviewUrl(bookId, entry.source_pdf_page)}
              entry={entry}
              decision={decision}
              sentences={matchingSentences}
              bboxesStale={currentChanged}
              onDecisionChange={editDecision}
            />
          </div>
          <div className={styles.canvasControls} aria-label="画布视图控制">
            <button type="button" aria-label="缩小画布" onClick={() => store.setZoom(clamp(store.zoom - 0.15, 0.6, 3))}><ZoomOut /></button>
            <span>{Math.round(store.zoom * 100)}%</span>
            <button type="button" aria-label="放大画布" onClick={() => store.setZoom(clamp(store.zoom + 0.15, 0.6, 3))}><ZoomIn /></button>
            <button type="button" onClick={() => { store.setZoom(1); store.setPan({ x: 0, y: 0 }); }}><Maximize2 />适合画布</button>
          </div>
        </main>

        <aside className={styles.inspector} aria-label="当前页属性">
          <div className={styles.inspectorHeading}>
            <span>当前源页</span><strong>第 {entry.source_pdf_page} 页</strong>
          </div>
          <dl className={styles.pageFacts}>
            <div><dt>自动判断</dt><dd data-warning={entry.detect.suspect_split || undefined}>{entry.detect.suspect_split ? "疑似双页" : "普通单页"}</dd></div>
            <div><dt>拆分置信度</dt><dd>{entry.detect.confidence}%</dd></div>
            <div><dt>输出阅读页</dt><dd>{decision.mode === "split_lr" ? 2 : 1} 页</dd></div>
            <div><dt>OCR 文字框</dt><dd>{matchingSentences.length || "--"}</dd></div>
          </dl>

          <section className={styles.inspectorSection}>
            <div className={styles.sectionTitle}><strong>拆分位置</strong><span>{decision.mode === "split_lr" ? `${Math.round((decision.split_ratio ?? 0.5) * 100)} / ${Math.round((1 - (decision.split_ratio ?? 0.5)) * 100)}` : "未拆分"}</span></div>
            <input
              type="range"
              min="10"
              max="90"
              step="1"
              value={Math.round((decision.split_ratio ?? 0.5) * 100)}
              disabled={decision.mode !== "split_lr"}
              aria-label="左页宽度百分比"
              onChange={(event) => editDecision({ ...decision, split_ratio: Number(event.target.value) / 100 })}
            />
            <div className={styles.splitValues}><span>左页 {Math.round((decision.split_ratio ?? 0.5) * 100)}%</span><span>右页 {Math.round((1 - (decision.split_ratio ?? 0.5)) * 100)}%</span></div>
          </section>

          <section className={styles.inspectorSection}>
            <div className={styles.sectionTitle}><strong>裁边（百分比）</strong><span>旋转 {decision.rotate}°</span></div>
            <div className={styles.cropGrid}>
              {(["top", "right", "bottom", "left"] as const).map((side) => (
                <label key={side}>
                  <span>{{ top: "上", right: "右", bottom: "下", left: "左" }[side]}</span>
                  <input
                    type="number"
                    min="0"
                    max="20"
                    step="0.5"
                    value={crop[side]}
                    onChange={(event) => editDecision({
                      ...decision,
                      crop_pct: {
                        ...crop,
                        [side]: clamp(Number(event.target.value), 0, 20),
                      },
                    })}
                  />
                  <b>%</b>
                </label>
              ))}
            </div>
            <button
              type="button"
              className={styles.resetCrop}
              onClick={() => editDecision({
                ...decision,
                crop_pct: { top: 0, right: 0, bottom: 0, left: 0 },
              })}
            >重置裁边</button>
          </section>

          <section className={styles.confirmSection}>
            <div>
              <strong>{decision.confirmed ? "本页已确认" : "本页等待确认"}</strong>
              <p>确认拆分、方向和裁边后再保存整本页面。</p>
            </div>
            <button
              type="button"
              data-confirmed={decision.confirmed || undefined}
              onClick={() => updateDecision({ ...decision, confirmed: !decision.confirmed }, !decision.confirmed)}
            >{decision.confirmed ? <Check /> : <Square />}{decision.confirmed ? "已确认" : "确认本页"}</button>
          </section>
        </aside>
      </div>

      <footer className={styles.footer}>
        <div className={styles.footerSummary}>
          <span><CheckCheck />已确认 {workspace.plan.source_pdf_page_count - unconfirmedCount} / {workspace.plan.source_pdf_page_count}</span>
          {unconfirmedCount > 0 && <button type="button" onClick={store.confirmAll}>全部确认</button>}
        </div>
        {confirming ? (
          <div className={styles.confirmSave} role="alert">
            <div><strong>重建页面会使 OCR、校对、语音和导出结果失效</strong><p>旧结果仍可追溯，但需要按顺序重新生成。</p></div>
            <button type="button" onClick={() => setConfirming(false)}>继续编辑</button>
            <button type="button" onClick={() => mutation.mutate()}>确认重建页面</button>
          </div>
        ) : (
          <div className={styles.footerActions}>
            <button
              type="button"
              className={styles.saveButton}
              disabled={!store.dirty || unconfirmedCount > 0 || mutation.isPending || ocrMutation.isPending}
              onClick={() => downstreamHasSuccess ? setConfirming(true) : mutation.mutate()}
            ><Save />{mutation.isPending ? "正在重建页面" : "应用页面决策"}</button>
            <button
              type="button"
              disabled={store.dirty || unconfirmedCount > 0 || mutation.isPending || ocrMutation.isPending}
              onClick={() => ocrMutation.mutate()}
            >{ocrMutation.isPending ? "正在识别文字" : "开始 OCR 与句子"}<ChevronRight /></button>
          </div>
        )}
      </footer>
    </section>
  );
}
