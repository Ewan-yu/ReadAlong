import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, CircleAlert, Headphones, LoaderCircle, Pause, Play, RefreshCw, Save, Waves, X } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

import {
  confirmOriginalAudioCandidate,
  disableOriginalAudioBackground,
  originalAudioCandidateAssetUrl,
  originalAudioSourceUrl,
  separateOriginalAudio,
} from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { bookStateQuery, originalAudioWorkspaceQuery } from "../../api/queries";
import styles from "./OriginalAudioReviewCard.module.css";

type Track = "original" | "vocals" | "background";

function clock(milliseconds?: number | null) {
  if (!milliseconds) return "--:--";
  const seconds = Math.round(milliseconds / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function Waveform({ src, label, active }: { src: string; label: string; active: boolean }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    let cancelled = false;
    void fetch(src).then((response) => response.json()).then((body: { peaks?: Array<[number, number]> }) => {
      if (cancelled || !canvas.current) return;
      const node = canvas.current;
      const rect = node.getBoundingClientRect();
      const pixelRatio = window.devicePixelRatio || 1;
      node.width = Math.max(1, Math.round(rect.width * pixelRatio));
      node.height = Math.max(1, Math.round(rect.height * pixelRatio));
      const context = node.getContext("2d");
      if (!context) return;
      context.scale(pixelRatio, pixelRatio);
      const width = rect.width;
      const height = rect.height;
      context.clearRect(0, 0, width, height);
      context.strokeStyle = getComputedStyle(node).getPropertyValue(
        active ? "--color-primary" : "--ink-400",
      );
      context.lineWidth = 1;
      const peaks = body.peaks ?? [];
      const step = peaks.length ? width / peaks.length : width;
      context.beginPath();
      peaks.forEach(([min, max], index) => {
        const x = index * step + step / 2;
        context.moveTo(x, height * (0.5 - max * 0.44));
        context.lineTo(x, height * (0.5 - min * 0.44));
      });
      context.stroke();
    }).catch(() => undefined);
    return () => { cancelled = true; };
  }, [active, src]);
  return <div className={styles.wave}><span>{label}</span><canvas ref={canvas} aria-label={`${label}波形`} role="img" /></div>;
}

export function OriginalAudioReviewCard({ bookId }: { bookId: string }) {
  const client = useQueryClient();
  const query = useQuery(originalAudioWorkspaceQuery(bookId));
  const [open, setOpen] = useState(false);
  const [track, setTrack] = useState<Track>("background");
  const [playing, setPlaying] = useState(false);
  const [resumeAt, setResumeAt] = useState(0);
  const audio = useRef<HTMLAudioElement>(null);
  const dialog = useRef<HTMLDialogElement>(null);
  const workspace = query.data;

  const refresh = async () => {
    await Promise.all([
      client.invalidateQueries(originalAudioWorkspaceQuery(bookId)),
      client.invalidateQueries(bookStateQuery(bookId)),
    ]);
  };
  const separate = useMutation({
    mutationFn: async () => {
      const run = await separateOriginalAudio(bookId);
      if (run.jobId) await waitForJob(run.jobId, () => undefined);
    },
    onSuccess: refresh,
  });
  const confirm = useMutation({ mutationFn: () => confirmOriginalAudioCandidate(bookId), onSuccess: async () => { await refresh(); setOpen(false); } });
  const disableBackground = useMutation({ mutationFn: () => disableOriginalAudioBackground(bookId), onSuccess: async () => { await refresh(); setOpen(false); } });

  useEffect(() => {
    const node = dialog.current;
    if (!node) return;
    if (open && !node.open) node.showModal();
    if (!open && node.open) node.close();
  }, [open]);
  useEffect(() => () => audio.current?.pause(), []);

  const candidate = workspace?.candidate_revision_id;
  const assets = workspace?.assets;
  const trackSource = useMemo(() => {
    if (!candidate || !assets) return "";
    if (track === "original") return originalAudioSourceUrl(bookId);
    return originalAudioCandidateAssetUrl(bookId, candidate, track === "vocals" ? assets.vocals_preview : assets.background_preview);
  }, [assets, bookId, candidate, track]);
  const selectTrack = (next: Track) => {
    const node = audio.current;
    setResumeAt(node?.currentTime ?? 0);
    setPlaying(Boolean(node && !node.paused));
    node?.pause();
    setTrack(next);
  };
  const togglePlayback = () => {
    const node = audio.current;
    if (!node) return;
    if (node.paused) void node.play().then(() => setPlaying(true)).catch(() => setPlaying(false));
    else { node.pause(); setPlaying(false); }
  };
  const restorePosition = () => {
    const node = audio.current;
    if (!node || !resumeAt) return;
    node.currentTime = resumeAt;
    if (playing) void node.play().catch(() => setPlaying(false));
  };
  if (query.isPending || !workspace) return null;
  if (!workspace.available) return null;
  const isBusy = separate.isPending || workspace.status === "processing";
  const ready = Boolean(candidate && assets && (workspace.status === "ready_for_review" || workspace.status === "confirmed"));
  const status = workspace.status === "confirmed" ? "已确认背景轨" : workspace.status === "voice_only" ? "纯人声路线" : workspace.status === "ready_for_review" ? "等待试听确认" : workspace.status === "processing" ? "正在分离" : workspace.status === "failed" ? "分离失败" : workspace.status === "stale" ? "需要重新分离" : "尚未处理";

  return <section className={styles.card} data-state={workspace.status}>
    <div className={styles.cardHeading}><span><Waves /></span><div><strong>原音处理</strong><small>{workspace.source_filename ?? "已上传原音"} · {clock(workspace.duration_ms)}</small></div><b>{status}</b></div>
    <p>{workspace.message ?? (workspace.status === "confirmed" ? "已确认的背景轨会在下一次导出中随资源包保存。" : ready ? "请比较人声与背景轨后，再确认保存。" : "原音只用于欣赏；孩子配音不会叠加完整原音。")}</p>
    {separate.error && <div className={styles.error}><CircleAlert />{separate.error.message}</div>}
    <div className={styles.actions}>
      {ready && <button type="button" className={styles.review} onClick={() => setOpen(true)}><Headphones />试听分离结果</button>}
      <button type="button" disabled={isBusy} onClick={() => separate.mutate()}><RefreshCw className={isBusy ? styles.spin : undefined} />{workspace.status === "not_processed" ? "开始分离" : "重新分离"}</button>
    </div>
    <dialog ref={dialog} className={styles.dialog} onCancel={(event) => { event.preventDefault(); setOpen(false); }} onClick={(event) => { if (event.target === dialog.current) setOpen(false); }}>
      <header><div><small>原音处理 / {workspace.source_filename}</small><h2>试听分离结果</h2><p>{workspace.model ?? "htdemucs"} · {clock(workspace.duration_ms)} · 只确认你愿意用于孩子作品的背景轨</p></div><button type="button" aria-label="关闭试听窗口" onClick={() => setOpen(false)}><X /></button></header>
      {ready && <main>
        <div className={styles.trackTabs} role="tablist" aria-label="试听轨道">
          {(["original", "vocals", "background"] as Track[]).map((item) => <button key={item} type="button" role="tab" aria-selected={track === item} onClick={() => selectTrack(item)}>{item === "original" ? "原音对照" : item === "vocals" ? "人声" : "背景与音效"}</button>)}
        </div>
        <div className={styles.waveforms}>
          <Waveform label="原音" active={track === "original"} src={originalAudioCandidateAssetUrl(bookId, candidate!, assets!.waveform_original)} />
          <Waveform label="人声" active={track === "vocals"} src={originalAudioCandidateAssetUrl(bookId, candidate!, assets!.waveform_vocals)} />
          <Waveform label="背景与音效" active={track === "background"} src={originalAudioCandidateAssetUrl(bookId, candidate!, assets!.waveform_background)} />
        </div>
        <div className={styles.player}><button type="button" className={styles.play} onClick={togglePlayback}>{playing ? <Pause /> : <Play />}{playing ? "暂停" : "播放"}</button><span>{track === "original" ? "原音仅用于对照，不会写入配音背景。" : track === "vocals" ? "确认旁白是否完整。" : "确认没有可辨识的原旁白和明显伪影。"}</span><audio ref={audio} src={trackSource} preload="metadata" onLoadedMetadata={restorePosition} onEnded={() => setPlaying(false)} /></div>
      </main>}
      <footer><button type="button" disabled={disableBackground.isPending} onClick={() => disableBackground.mutate()}>不使用背景轨</button><button type="button" onClick={() => setOpen(false)}>稍后再说</button><button type="button" disabled={confirm.isPending || workspace.status === "confirmed"} className={styles.confirm} onClick={() => confirm.mutate()}>{confirm.isPending ? <LoaderCircle className={styles.spin} /> : <Save />}{workspace.status === "confirmed" ? "已确认保存" : "确认并保存"}</button></footer>
    </dialog>
  </section>;
}
