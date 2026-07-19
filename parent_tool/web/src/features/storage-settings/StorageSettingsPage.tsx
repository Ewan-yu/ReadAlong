import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, CheckCircle2, Database, FileAudio, FolderInput, HardDrive, LoaderCircle, MicVocal, RefreshCw, RotateCcw, Star, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";

import { createGeneratedVoice, deleteVoiceProfile, recalculateStorage, startStorageMigration, updateVoiceProfile, uploadVoiceProfile, voicePreviewUrl, type ApiRequestError } from "../../api/client";
import { storageMigrationQuery, storageQuery, voicesQuery } from "../../api/queries";
import styles from "./StorageSettingsPage.module.css";

function bytes(value: number) {
  if (value < 1024 * 1024) return `${Math.max(1, value / 1024).toFixed(0)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export function StorageSettingsPage() {
  const client = useQueryClient();
  const storage = useQuery(storageQuery);
  const voices = useQuery(voicesQuery);
  const [target, setTarget] = useState("");
  const [migrationId, setMigrationId] = useState<string>();
  const [generatedName, setGeneratedName] = useState("温暖女老师");
  const [generatedDescription, setGeneratedDescription] = useState("warm female kindergarten teacher, slow and clear");
  const [uploadedName, setUploadedName] = useState("");
  const [uploadedFile, setUploadedFile] = useState<File>();
  const migration = useQuery({ ...storageMigrationQuery(migrationId ?? ""), enabled: Boolean(migrationId) });
  const recalculate = useMutation({
    mutationFn: recalculateStorage,
    onSuccess: (data) => client.setQueryData(["storage"], data),
  });
  const move = useMutation({
    mutationFn: startStorageMigration,
    onSuccess: (data) => setMigrationId(data.migration_id),
  });
  const createGenerated = useMutation({ mutationFn: () => createGeneratedVoice(generatedName.trim(), generatedDescription.trim()), onSuccess: () => void client.invalidateQueries({ queryKey: ["voices"] }) });
  const upload = useMutation({ mutationFn: () => uploadedFile ? uploadVoiceProfile(uploadedName.trim(), uploadedFile) : Promise.reject(new Error("请选择声音文件")), onSuccess: () => { setUploadedFile(undefined); setUploadedName(""); void client.invalidateQueries({ queryKey: ["voices"] }); } });
  const updateVoice = useMutation({ mutationFn: ({ id, isDefault }: { id: string; isDefault: boolean }) => updateVoiceProfile(id, { is_default: isDefault }), onSuccess: () => void client.invalidateQueries({ queryKey: ["voices"] }) });
  const removeVoice = useMutation({ mutationFn: deleteVoiceProfile, onSuccess: () => void client.invalidateQueries({ queryKey: ["voices"] }) });
  useEffect(() => {
    if (migration.data?.phase === "switched") void client.invalidateQueries({ queryKey: ["storage"] });
  }, [client, migration.data?.phase]);

  if (storage.isPending) return <div className={styles.state}><LoaderCircle className={styles.spin} />正在读取存储设置…</div>;
  if (storage.isError) return <div className={styles.state} role="alert"><AlertTriangle />{(storage.error as ApiRequestError).message}</div>;
  const data = storage.data;
  const locked = data.managed_by === "environment";
  const active = migration.data;
  const migrating = active && !["switched", "failed"].includes(active.phase);
  return <section className={styles.page}>
    <header className={styles.header}><div><p>本机设置 / 数据与存储</p><h1>把制作资料放在合适的位置</h1><span>项目文件只保存在你的电脑；迁移会先完整复制和校验，再切换到新位置。</span></div><button type="button" onClick={() => recalculate.mutate()} disabled={recalculate.isPending}><RefreshCw className={recalculate.isPending ? styles.spin : undefined} />重新统计</button></header>

    <div className={styles.metrics}>
      <div><HardDrive /><span><small>项目占用</small><strong>{bytes(data.used_bytes)}</strong><em>{data.workspace_count} 个制作项目</em></span></div>
      <div><Database /><span><small>当前磁盘可用</small><strong>{bytes(data.disk_free_bytes)}</strong><em>总容量 {bytes(data.disk_total_bytes)}</em></span></div>
    </div>

    <section className={styles.location}>
      <div className={styles.sectionTitle}><FolderInput /><div><h2>数据目录</h2><p>页面图、OCR、音频和导出版本都会保存在这里。</p></div></div>
      <label><span>当前目录</span><code title={data.workspace_root}>{data.workspace_root}</code></label>
      {locked ? <p className={styles.notice}><AlertTriangle />该位置由环境变量 READALONG_WORKSPACE_ROOT 管理。若要更换，请先关闭服务并修改环境变量。</p> : <><div className={styles.change}><label><span>新目录</span><input value={target} disabled={Boolean(migrating)} onChange={(event) => setTarget(event.target.value)} placeholder="例如 D:\\ReadAlongData" /></label><button type="button" disabled={!target.trim() || Boolean(migrating) || move.isPending} onClick={() => move.mutate(target.trim())}>{move.isPending || migrating ? <LoaderCircle className={styles.spin} /> : <RotateCcw />}迁移到这里</button></div><p className={styles.help}>请选择不存在或空的本地绝对路径。需要目标磁盘保留当前占用额外 10% 的空间。</p></>}
      {move.isError && <p className={styles.error} role="alert"><AlertTriangle />{(move.error as ApiRequestError).message}</p>}
    </section>

    {active && <section className={styles.migration} data-tone={active.phase} aria-live="polite"><div className={styles.migrationHeading}>{active.phase === "failed" ? <AlertTriangle /> : active.phase === "switched" ? <CheckCircle2 /> : <LoaderCircle className={styles.spin} />}<div><strong>{active.phase === "switched" ? "迁移已准备完成" : active.phase === "failed" ? "迁移没有完成" : "正在迁移数据"}</strong><span>{active.message}</span></div></div><div className={styles.track}><i style={{ width: `${Math.round(active.progress * 100)}%` }} /></div><small>{Math.round(active.progress * 100)}% · {bytes(active.copied_bytes)} / {bytes(active.total_bytes)}</small>{active.restart_required && <p className={styles.restart}>现在请关闭并重新启动家长端。新目录确认可用后，旧目录会自动清理以释放空间。</p>}{active.error && <p className={styles.error}>{active.error.message}</p>}</section>}

    <section className={styles.voices} aria-labelledby="voice-library-title"><div className={styles.sectionTitle}><MicVocal /><div><h2 id="voice-library-title">声音样本</h2><p>先建立并试听固定参考声；语音页选择后，整书与单句重生成都会保持同一声线。</p></div></div><div className={styles.voiceList}>{voices.isPending && <p className={styles.voiceState}><LoaderCircle className={styles.spin} />正在读取声音样本…</p>}{voices.isError && <p className={styles.error}><AlertTriangle />{(voices.error as ApiRequestError).message}</p>}{voices.data?.map((voice) => <article className={styles.voiceCard} key={voice.voice_id} data-state={voice.status}><div className={styles.voiceTitle}><span>{voice.source_type === "uploaded" ? <FileAudio /> : <MicVocal />}</span><div><strong>{voice.name}</strong><small>{voice.source_type === "uploaded" ? "上传克隆样本" : "系统生成声音"}{voice.is_default ? " · 默认" : ""}</small></div>{voice.is_default && <Star className={styles.defaultStar} fill="currentColor" />}</div>{voice.status === "ready" ? <><audio controls preload="none" src={voicePreviewUrl(voice.voice_id)} /><p>{voice.reference_duration_seconds?.toFixed(1)} 秒参考声。实际合成试听，而非原始录音。</p><div className={styles.voiceActions}>{!voice.is_default && <button type="button" onClick={() => updateVoice.mutate({ id: voice.voice_id, isDefault: true })}><Star />设为默认</button>}{!voice.is_system && <button type="button" data-danger onClick={() => removeVoice.mutate(voice.voice_id)} disabled={voice.is_default}><Trash2 />删除</button>}</div></> : voice.status === "failed" ? <p className={styles.voiceFailure}><AlertTriangle />{voice.failure_message ?? "处理失败，请重新创建样本。"}</p> : <p className={styles.voiceState}><LoaderCircle className={styles.spin} />{voice.progress_message ?? "正在处理声音样本…"}</p>}{voice.warnings.map((warning) => <small className={styles.voiceWarning} key={warning}>{warning}</small>)}</article>)}</div><div className={styles.voiceCreate}><form onSubmit={(event) => { event.preventDefault(); if (generatedName.trim() && generatedDescription.trim()) createGenerated.mutate(); }}><h3>系统生成声音</h3><p>用描述生成一次干净参考声，再合成固定试听。</p><input value={generatedName} onChange={(event) => setGeneratedName(event.target.value)} placeholder="样本名称" /><input value={generatedDescription} onChange={(event) => setGeneratedDescription(event.target.value)} placeholder="英文声音描述" /><button disabled={createGenerated.isPending || !generatedName.trim() || generatedDescription.trim().length < 3} type="submit"><MicVocal />创建并生成试听</button></form><form onSubmit={(event) => { event.preventDefault(); if (uploadedFile && uploadedName.trim()) upload.mutate(); }}><h3>上传克隆样本</h3><p>上传 3–15 秒清晰、无音乐、单人 WAV 或 MP3；系统会生成真实克隆试听。</p><input value={uploadedName} onChange={(event) => setUploadedName(event.target.value)} placeholder="样本名称" /><input type="file" accept="audio/wav,audio/mpeg,.wav,.mp3" onChange={(event) => setUploadedFile(event.target.files?.[0])} /><button disabled={upload.isPending || !uploadedFile || !uploadedName.trim()} type="submit"><FileAudio />上传并生成试听</button></form></div>{(createGenerated.isError || upload.isError || updateVoice.isError || removeVoice.isError) && <p className={styles.error} role="alert"><AlertTriangle />{((createGenerated.error ?? upload.error ?? updateVoice.error ?? removeVoice.error) as Error).message}</p>}</section>
  </section>;
}
