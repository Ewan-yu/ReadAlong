import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useParams } from "@tanstack/react-router";
import { AlertTriangle, Check, CircleAlert, Headphones, LoaderCircle, Play, RotateCcw, SlidersHorizontal, Sparkles } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import { audioAssetUrl, runAudio, type ApiRequestError, type AudioParams, type AudioWorkspaceSentence } from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { audioWorkspaceQuery, bookStateQuery } from "../../api/queries";
import styles from "./AudioGenerationPage.module.css";

const presets = [
  ["温暖女老师", "warm female kindergarten teacher, slow and clear"],
  ["活泼故事家", "playful female story narrator, expressive and bright"],
  ["沉稳男声", "calm male storyteller, gentle and clear"],
] as const;

function seconds(value: number | null | undefined) {
  return value ? `${value.toFixed(1)} 秒` : "--";
}

function reportStatus(item: AudioWorkspaceSentence) {
  const report = item.report;
  if (!report) return { label: "等待生成", tone: "waiting" };
  if (!report.audio_path) return { label: "生成失败", tone: "failed" };
  if (!report.word_timing) return { label: "无逐词高亮", tone: "warning" };
  if (report.error_code?.startsWith("TIMING_ESTIMATED_")) return { label: "估算逐词高亮", tone: "estimated" };
  if (report.suspect_tts) return { label: "建议试听", tone: "warning" };
  return { label: "已完成", tone: "done" };
}

export function AudioGenerationPage() {
  const { bookId } = useParams({ strict: false }) as { bookId: string };
  const navigate = useNavigate();
  const client = useQueryClient();
  const query = useQuery(audioWorkspaceQuery(bookId));
  const stateQuery = useQuery(bookStateQuery(bookId));
  const [params, setParams] = useState<AudioParams>();
  const [jobProgress, setJobProgress] = useState(0);
  const [resumedJobId, setResumedJobId] = useState<string>();
  const [jobMessage, setJobMessage] = useState<string>();
  const [playing, setPlaying] = useState<string>();
  const resumedJobs = useRef(new Set<string>());
  const audio = useRef<HTMLAudioElement | undefined>(undefined);
  const workspace = query.data;

  useEffect(() => { if (workspace) setParams(workspace.params); }, [workspace?.audio_revision_id, workspace?.proofread_revision_id]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => audio.current?.pause(), []);
  const activeJobId = stateQuery.data?.steps.audio.active_attempt?.job_id;
  const lastAttempt = stateQuery.data?.steps.audio.last_attempt;

  useEffect(() => {
    if (!activeJobId || resumedJobs.current.has(activeJobId)) return;
    resumedJobs.current.add(activeJobId);
    setResumedJobId(activeJobId);
    setJobProgress(0);
    setJobMessage("正在恢复音频生成进度…");
    void waitForJob(activeJobId, (snapshot) => {
      setJobProgress(snapshot.progress);
      setJobMessage(snapshot.message);
    }).then(async () => {
      await Promise.all([client.invalidateQueries({ queryKey: ["books", bookId, "audio"] }), client.invalidateQueries(bookStateQuery(bookId))]);
    }).catch(() => {
      void client.invalidateQueries(bookStateQuery(bookId));
    }).finally(() => setResumedJobId(undefined));
  }, [activeJobId, bookId, client]);

  const metrics = useMemo(() => {
    const reports = workspace?.sentences.map((item) => item.report).filter(Boolean) ?? [];
    return {
      total: workspace?.sentences.length ?? 0,
      done: reports.filter((item) => item?.audio_path).length,
      timing: reports.filter((item) => item?.word_timing).length,
      estimatedTiming: reports.filter((item) => item?.word_timing && item.error_code?.startsWith("TIMING_ESTIMATED_")).length,
      failed: reports.filter((item) => !item?.audio_path).length,
    };
  }, [workspace]);
  const mutate = useMutation({
    mutationFn: async (next: AudioParams) => {
      setJobProgress(0);
      setJobMessage("正在提交音频生成任务…");
      const run = await runAudio(bookId, next);
      if (run.jobId) await waitForJob(run.jobId, (snapshot) => { setJobProgress(snapshot.progress); setJobMessage(snapshot.message); });
    },
    onSuccess: async () => {
      await Promise.all([client.invalidateQueries({ queryKey: ["books", bookId, "audio"] }), client.invalidateQueries(bookStateQuery(bookId))]);
    },
  });
  if (query.isPending || !params) return <div className={styles.state}><LoaderCircle className={styles.spin} /><p>正在准备语音生成工作区…</p></div>;
  if (query.isError || !workspace) { const error = query.error as ApiRequestError | null; return <div className={styles.state} role="alert"><CircleAlert /><h1>语音生成页暂时无法打开</h1><p>{error?.message ?? "请先发布 OCR 校对结果。"}</p></div>; }
  const error = mutate.error as ApiRequestError | null;
  const persistedFailure = !activeJobId && (lastAttempt?.status === "failed" || lastAttempt?.status === "interrupted") ? lastAttempt.error : null;
  const failureMessage = error?.message ?? persistedFailure?.message;
  const isRunning = mutate.isPending || Boolean(activeJobId) || Boolean(resumedJobId);
  const update = (patch: Partial<AudioParams>) => setParams((current) => current ? { ...current, ...patch } : current);
  const start = () => mutate.mutate({ ...params, sentence_ids: [], base_audio_revision: null });
  const regenerate = (sentenceId: string) => {
    if (!workspace.audio_revision_id) return start();
    mutate.mutate({ ...params, sentence_ids: [sentenceId], base_audio_revision: workspace.audio_revision_id });
  };
  const listen = (item: AudioWorkspaceSentence) => {
    if (!workspace.audio_revision_id || !item.report?.audio_path) return;
    audio.current?.pause();
    const next = new Audio(audioAssetUrl(bookId, workspace.audio_revision_id, item.report.audio_path));
    audio.current = next; setPlaying(item.sentence.id);
    next.onended = () => setPlaying(undefined); next.onerror = () => setPlaying(undefined);
    void next.play().catch(() => setPlaying(undefined));
  };
  const progress = metrics.total ? metrics.done / metrics.total : 0;
  const canExport = Boolean(workspace.audio_revision_id && metrics.done === metrics.total && metrics.failed === 0);

  return <section className={styles.page}>
    <header className={styles.header}><div><p>工作区 / {bookId}</p><h1>语音生成与试听</h1></div><div className={styles.headerActions}><span>{isRunning ? "音频生成进行中" : workspace.audio_revision_id ? metrics.failed ? "音频结果含失败项" : "音频结果已发布" : "等待生成"}</span><button type="button" className={styles.primary} disabled={isRunning} onClick={start}><Sparkles />{workspace.audio_revision_id ? "按当前音色重生成全书" : "开始生成全书"}</button></div></header>
    {failureMessage && <div className={styles.error} role="alert"><CircleAlert /><span><strong>语音生成未完成。</strong>{failureMessage}</span><button type="button" disabled={isRunning} onClick={start}><RotateCcw />重新生成全书</button></div>}
    {isRunning && <div className={styles.progress}><LoaderCircle className={styles.spin} /><span>{jobMessage ?? "正在合成、对齐并转码…"}</span><b>{Math.round(jobProgress * 100)}%</b><i style={{ transform: `scaleX(${jobProgress})` }} /></div>}
    <div className={styles.metrics}><div><small>当前音色</small><strong>{params.voice.mode === "clone" ? "导入原音克隆" : presets.find((item) => item[1] === params.voice.description)?.[0] ?? "自定义描述"}</strong></div><div><small>生成进度</small><strong>{metrics.done} / {metrics.total}</strong><i><em style={{ transform: `scaleX(${progress})` }} /></i></div><div><small>词级时间戳</small><strong>{metrics.timing} 句</strong>{metrics.estimatedTiming > 0 && <span>{metrics.estimatedTiming} 句为估算高亮</span>}</div><div><small>需要处理</small><strong data-warning={metrics.failed > 0 || undefined}>{metrics.failed || "无"}</strong></div></div>
    <div className={styles.layout}><main className={styles.tablePanel}><div className={styles.tableHeading}><div><strong>句子试听队列</strong><span>橙色项目可导出，但建议先试听或重生成。</span></div><button type="button" disabled={!metrics.failed || mutate.isPending} onClick={() => { const target = workspace.sentences.find((item) => !item.report?.audio_path); if (target) regenerate(target.sentence.id); }}><RotateCcw />重试失败项</button></div><div className={styles.table} role="table"><div className={styles.tableHead} role="row"><span>ID</span><span>文本</span><span>时长</span><span>状态</span><span>操作</span></div>{workspace.sentences.map((item) => { const status = reportStatus(item); return <div className={styles.row} role="row" key={item.sentence.id} data-tone={status.tone}><span className={styles.id}>{item.sentence.id}</span><p>{item.sentence.text}</p><span>{seconds(item.report?.duration_seconds)}</span><span className={styles.status} data-tone={status.tone}>{status.tone === "done" ? <Check /> : status.tone === "warning" ? <AlertTriangle /> : <CircleAlert />}{status.label}</span><div className={styles.rowActions}><button type="button" aria-label={`试听 ${item.sentence.id}`} disabled={!item.report?.audio_path} data-playing={playing === item.sentence.id || undefined} onClick={() => listen(item)}><Play />{playing === item.sentence.id ? "播放中" : "试听"}</button><button type="button" disabled={mutate.isPending} onClick={() => regenerate(item.sentence.id)}><RotateCcw />重生成</button></div></div>; })}</div></main>
      <aside className={styles.settings}><div className={styles.settingsHeading}><SlidersHorizontal /><div><strong>音色设置</strong><span>系统音色会先建立一段干净的统一声线，再生成整书。</span></div></div><label><span>音色预设</span><select value={presets.some((item) => item[1] === params.voice.description) ? params.voice.description : "custom"} disabled={params.voice.mode === "clone" || isRunning} onChange={(event) => { if (event.target.value !== "custom") update({ voice: { ...params.voice, mode: "design", description: event.target.value, reference_wav_path: null } }); }}><option value={presets[0][1]}>{presets[0][0]}</option>{presets.slice(1).map((item) => <option key={item[1]} value={item[1]}>{item[0]}</option>)}<option value="custom">自定义描述</option></select></label><label><span>音色描述</span><textarea value={params.voice.description} disabled={params.voice.mode === "clone" || isRunning} onChange={(event) => update({ voice: { ...params.voice, description: event.target.value } })} /></label><label className={styles.clone}><input type="checkbox" checked={params.voice.mode === "clone"} disabled={!workspace.original_audio_path || isRunning} onChange={(event) => update({ voice: event.target.checked ? { ...params.voice, mode: "clone", reference_wav_path: workspace.original_audio_path } : { ...params.voice, mode: "design", reference_wav_path: null } })} /><span><strong>使用导入原音克隆（仅无音乐人声）</strong><small>{workspace.original_audio_path ? "导入原音若含配乐、音效或多人说话，克隆结果会带入干扰；建议关闭并使用系统音色。" : "未导入原音，当前不可用。"}</small></span></label><label className={styles.speed}><span>语速</span><input type="range" min="0.75" max="1.25" step="0.05" value={params.tempo ?? 0.9} disabled={isRunning} onChange={(event) => update({ tempo: Number(event.target.value) })} /><b>{params.tempo?.toFixed(2)}×</b></label><div className={styles.settingsNote}><Headphones /><p>完成句可随时试听；单句重生成会复用同一校对版本中其他可用音频。</p></div></aside></div>
    <footer className={styles.footer}><span>{canExport ? "生成完成后可进入资源导出。" : metrics.failed ? "仍有失败句，请重试后再导出。" : "请先生成全书语音。"}</span><button type="button" disabled={!canExport || mutate.isPending} onClick={() => void navigate({ to: "/books/$bookId/export", params: { bookId } })}>继续导出资源包</button></footer>
  </section>;
}
