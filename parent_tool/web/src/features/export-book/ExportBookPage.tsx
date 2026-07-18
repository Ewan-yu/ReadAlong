import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { Archive, Check, CheckCircle2, CircleAlert, ClipboardCheck, Download, FileArchive, FileText, Info, LoaderCircle, RefreshCw, TriangleAlert } from "lucide-react";
import { useEffect, useMemo, useState } from "react";

import { exportDownloadUrl, runExport, type ApiRequestError } from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { bookStateQuery, exportWorkspaceQuery } from "../../api/queries";
import styles from "./ExportBookPage.module.css";

function bytes(value: number | null | undefined) {
  if (!value) return "生成后计算";
  return value < 1024 * 1024 ? `${Math.ceil(value / 1024)} KB` : `${(value / 1024 / 1024).toFixed(1)} MB`;
}

const icon = { pass: CheckCircle2, warning: TriangleAlert, error: CircleAlert } as const;

export function ExportBookPage() {
  const { bookId } = useParams({ strict: false }) as { bookId: string };
  const client = useQueryClient();
  const query = useQuery(exportWorkspaceQuery(bookId));
  const [title, setTitle] = useState("");
  const [progress, setProgress] = useState(0);
  const workspace = query.data;
  useEffect(() => { if (workspace) setTitle(workspace.suggested_title); }, [workspace?.suggested_title]);
  const counts = useMemo(() => ({ pass: workspace?.checks.filter((item) => item.status === "pass").length ?? 0, warning: workspace?.checks.filter((item) => item.status === "warning").length ?? 0, error: workspace?.checks.filter((item) => item.status === "error").length ?? 0 }), [workspace]);
  const mutation = useMutation({
    mutationFn: async () => { setProgress(0); const run = await runExport(bookId, title.trim()); if (run.jobId) await waitForJob(run.jobId, (job) => setProgress(job.progress)); },
    onSuccess: async () => { await Promise.all([client.invalidateQueries({ queryKey: ["books", bookId, "export"] }), client.invalidateQueries(bookStateQuery(bookId))]); },
  });
  if (query.isPending) return <div className={styles.state}><LoaderCircle className={styles.spin} /><p>正在检查资源包组成…</p></div>;
  if (query.isError || !workspace) { const error = query.error as ApiRequestError | null; return <div className={styles.state} role="alert"><CircleAlert /><h1>导出工作区暂时无法打开</h1><p>{error?.message ?? "请先完成语音生成。"}</p></div>; }
  const error = mutation.error as ApiRequestError | null;
  const hasBundle = Boolean(workspace.export_revision_id);

  return <section className={styles.page}>
    <header className={styles.header}><div><p>工作区 / {bookId}</p><h1>导出阅读资源包</h1><span>{workspace.ready ? "全部必要产物已就绪，可以生成标准 .readalongbook。" : "请先处理下方标记为错误的项目。"}</span></div><div className={styles.headerMark}><Archive /><strong>{workspace.ready ? "可导出" : "等待处理"}</strong></div></header>
    {error && <div className={styles.error}><CircleAlert />{error.message}</div>}
    {mutation.isPending && <div className={styles.progress}><LoaderCircle className={styles.spin} /><span>正在组装 manifest、页面、音频与 alignment…</span><b>{Math.round(progress * 100)}%</b><i style={{ transform: `scaleX(${progress})` }} /></div>}
    <div className={styles.layout}><main className={styles.main}><section className={styles.overview}><div><strong>{counts.pass}</strong><span>通过</span></div><div data-warning={counts.warning || undefined}><strong>{counts.warning}</strong><span>提示</span></div><div data-error={counts.error || undefined}><strong>{counts.error}</strong><span>错误</span></div><p><Info />词级时间戳缺失会降级为整句字幕，仍可安全导出。</p></section><section className={styles.checks}><div className={styles.sectionHeading}><div><ClipboardCheck /><div><strong>导出前校验</strong><span>资源包所有必要内容在生成前再次核对。</span></div></div><button type="button" onClick={() => void query.refetch()}><RefreshCw />刷新状态</button></div>{workspace.checks.map((check) => { const Icon = icon[check.status]; return <article key={check.id} data-status={check.status}><Icon /><div><strong>{check.label}</strong><p>{check.detail}</p></div><span>{check.status === "pass" ? "通过" : check.status === "warning" ? "提示" : "需处理"}</span></article>; })}</section><section className={styles.guide}><FileText /><div><strong>导入平板</strong><ol><li>下载或拷贝生成的 <code>.readalongbook</code> 文件。</li><li>在平板上的 ReadAlong 跟读宝中点击“导入资源包”。</li><li>选择文件后，书架会显示新绘本并进行完整校验。</li></ol></div></section></main><aside className={styles.side}><section className={styles.package}><FileArchive /><div><span>资源包信息</span><strong>{workspace.package.filename}</strong></div><dl><div><dt>阅读页</dt><dd>{workspace.package.page_count}</dd></div><div><dt>校对句子</dt><dd>{workspace.package.sentence_count}</dd></div><div><dt>词级时间</dt><dd>{workspace.package.word_timing_sentence_count} 句</dd></div><div><dt>图片格式</dt><dd>WebP + JPEG</dd></div><div><dt>音频来源</dt><dd>{Object.entries(workspace.package.audio_provider_counts).map(([name, count]) => `${name} ${count}`).join(" · ") || "--"}</dd></div><div><dt>包大小</dt><dd>{bytes(workspace.package.size_bytes)}</dd></div></dl>{workspace.package.sha256 && <code title={workspace.package.sha256}>{workspace.package.sha256.slice(0, 16)}…</code>}</section><label className={styles.titleField}><span>书名（manifest）</span><input value={title} maxLength={120} onChange={(event) => setTitle(event.target.value)} /></label><button type="button" className={styles.export} disabled={!workspace.ready || mutation.isPending} onClick={() => mutation.mutate()}>{hasBundle ? <RefreshCw /> : <Download />}{hasBundle ? "重新生成资源包" : "导出 .readalongbook"}</button>{hasBundle && <a className={styles.download} href={exportDownloadUrl(bookId, workspace.export_revision_id!)} download><Download />下载资源包</a>}<p className={styles.sideNote}>{workspace.ready ? "导出会发布新的不可变 revision，旧资源包仍可追溯。" : "错误消除后，导出按钮会自动可用。"}</p></aside></div>
  </section>;
}
