import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, Check, FileAudio, LoaderCircle, MicVocal, Pencil, Plus, Star, Trash2, Volume2, X } from "lucide-react";
import { useState } from "react";

import { createGeneratedVoice, deleteVoiceProfile, updateVoiceProfile, uploadVoiceProfile, voicePreviewUrl, type ApiRequestError, type VoiceProfile } from "../../api/client";
import { voicesQuery } from "../../api/queries";
import styles from "./VoiceProfilesPage.module.css";

function VoiceCard({ voice, onDefault, onDelete, onRename, busy }: { voice: VoiceProfile; onDefault: () => void; onDelete: () => void; onRename: (name: string) => void; busy: boolean }) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(voice.name);
  return <article className={styles.voiceCard} data-state={voice.status}>
    <div className={styles.voiceTitle}><span>{voice.source_type === "uploaded" ? <FileAudio /> : <MicVocal />}</span><div>{editing ? <form className={styles.rename} onSubmit={(event) => { event.preventDefault(); if (name.trim()) { onRename(name.trim()); setEditing(false); } }}><input aria-label="样本名称" value={name} onChange={(event) => setName(event.target.value)} /><button aria-label="保存名称" disabled={busy} type="submit"><Check /></button><button aria-label="取消重命名" type="button" onClick={() => { setName(voice.name); setEditing(false); }}><X /></button></form> : <><strong>{voice.name}</strong><small>{voice.source_type === "uploaded" ? "上传克隆样本" : "系统生成声音"}</small></>}</div>{!editing && <button className={styles.renameButton} type="button" aria-label={`重命名 ${voice.name}`} onClick={() => setEditing(true)}><Pencil /></button>}{voice.is_default && <span className={styles.default}><Star fill="currentColor" />默认声音</span>}</div>
    {voice.status === "ready" ? <><audio controls preload="none" src={voicePreviewUrl(voice.voice_id)} /><div className={styles.meta}><span>{voice.reference_duration_seconds?.toFixed(1)} 秒参考声</span><span>实际克隆试听</span></div><div className={styles.actions}>{!voice.is_default && <button type="button" disabled={busy} onClick={onDefault}><Star />设为默认</button>}{!voice.is_system && <button type="button" data-danger disabled={busy || voice.is_default} onClick={onDelete}><Trash2 />删除</button>}</div></> : voice.status === "failed" ? <p className={styles.failure}><AlertTriangle />{voice.failure_message ?? "处理失败，请重新创建样本。"}</p> : <p className={styles.processing}><LoaderCircle className={styles.spin} />{voice.progress_message ?? "正在处理声音样本…"}</p>}
    {voice.warnings.map((warning) => <small className={styles.warning} key={warning}>{warning}</small>)}
  </article>;
}

export function VoiceProfilesPage() {
  const client = useQueryClient();
  const voices = useQuery(voicesQuery);
  const [generatedName, setGeneratedName] = useState("温暖女老师");
  const [generatedDescription, setGeneratedDescription] = useState("warm female kindergarten teacher, slow and clear");
  const [uploadedName, setUploadedName] = useState("");
  const [uploadedFile, setUploadedFile] = useState<File>();
  const refresh = () => void client.invalidateQueries({ queryKey: ["voices"] });
  const createGenerated = useMutation({ mutationFn: () => createGeneratedVoice(generatedName.trim(), generatedDescription.trim()), onSuccess: refresh });
  const upload = useMutation({ mutationFn: () => uploadedFile ? uploadVoiceProfile(uploadedName.trim(), uploadedFile) : Promise.reject(new Error("请选择声音文件")), onSuccess: () => { setUploadedFile(undefined); setUploadedName(""); refresh(); } });
  const updateVoice = useMutation({ mutationFn: ({ id, patch }: { id: string; patch: { is_default?: boolean; name?: string } }) => updateVoiceProfile(id, patch), onSuccess: refresh });
  const removeVoice = useMutation({ mutationFn: deleteVoiceProfile, onSuccess: refresh });
  const items = voices.data ?? [];
  const ready = items.filter((voice) => voice.status === "ready").length;
  const busy = createGenerated.isPending || upload.isPending || updateVoice.isPending || removeVoice.isPending;
  const error = createGenerated.error ?? upload.error ?? updateVoice.error ?? removeVoice.error;
  return <section className={styles.page}>
    <header className={styles.header}><div><p>设置 / 声音样本</p><h1>声音样本库</h1><span>先确认真实试听，再把声音用于整书。生成后的单句修复始终复用原书快照。</span></div><div className={styles.summary}><Volume2 /><span><strong>{ready}</strong><small>个可用声音</small></span></div></header>
    <section className={styles.library}><div className={styles.libraryHeading}><div><h2>我的声音</h2><p>默认声音会在新建语音任务时优先选中，仍可在每本书中切换。</p></div><span>{items.length} 个样本</span></div>{voices.isPending ? <p className={styles.state}><LoaderCircle className={styles.spin} />正在读取声音样本…</p> : voices.isError ? <p className={styles.failure}><AlertTriangle />{(voices.error as ApiRequestError).message}</p> : items.length ? <div className={styles.voiceGrid}>{items.map((voice) => <VoiceCard key={voice.voice_id} voice={voice} busy={busy} onDefault={() => updateVoice.mutate({ id: voice.voice_id, patch: { is_default: true } })} onRename={(name) => updateVoice.mutate({ id: voice.voice_id, patch: { name } })} onDelete={() => removeVoice.mutate(voice.voice_id)} />)}</div> : <div className={styles.empty}><MicVocal /><div><strong>从一个声音开始</strong><p>创建系统生成声音，或上传一段清晰人声来制作克隆样本。</p></div></div>}</section>
    <section className={styles.create}><div className={styles.createLead}><Plus /><div><h2>添加声音样本</h2><p>每个样本都先生成固定参考声和实际克隆试听；试听满意后才建议设为默认。</p></div></div><div className={styles.createForms}><form onSubmit={(event) => { event.preventDefault(); if (generatedName.trim() && generatedDescription.trim()) createGenerated.mutate(); }}><h3>系统生成</h3><p>使用描述一次性生成干净、可复用的参考声。</p><label>样本名称<input value={generatedName} onChange={(event) => setGeneratedName(event.target.value)} placeholder="例如：温暖女老师" /></label><label>声音描述<textarea value={generatedDescription} onChange={(event) => setGeneratedDescription(event.target.value)} placeholder="使用你自己的声音描述" /></label><button disabled={busy || !generatedName.trim() || generatedDescription.trim().length < 3} type="submit"><MicVocal />创建并生成试听</button></form><form onSubmit={(event) => { event.preventDefault(); if (uploadedFile && uploadedName.trim()) upload.mutate(); }}><h3>上传克隆</h3><p>上传 3–15 秒清晰、无音乐、单人 WAV 或 MP3。</p><label>样本名称<input value={uploadedName} onChange={(event) => setUploadedName(event.target.value)} placeholder="例如：妈妈的故事声" /></label><label>参考音频<input type="file" accept="audio/wav,audio/mpeg,.wav,.mp3" onChange={(event) => setUploadedFile(event.target.files?.[0])} /></label><button disabled={busy || !uploadedFile || !uploadedName.trim()} type="submit"><FileAudio />上传并生成试听</button></form></div>{error && <p className={styles.failure} role="alert"><AlertTriangle />{(error as Error).message}</p>}</section>
  </section>;
}
