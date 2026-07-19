import { useQuery } from "@tanstack/react-query";
import { FolderCog, HardDrive, LoaderCircle, MicVocal, Settings2, Volume2 } from "lucide-react";
import { useNavigate } from "@tanstack/react-router";

import { storageQuery, voicesQuery } from "../../api/queries";
import styles from "./SettingsHomePage.module.css";

export function SettingsHomePage() {
  const navigate = useNavigate();
  const storage = useQuery(storageQuery);
  const voices = useQuery(voicesQuery);
  const readyVoiceCount = voices.data?.filter((voice) => voice.status === "ready").length;
  return <section className={styles.page}>
    <header><p>本机设置</p><h1>让加工台长期好用</h1><span>把每一类设置放在独立空间中管理，后续功能也会在这里逐步扩展。</span></header>
    <div className={styles.groups}><section><div className={styles.groupLabel}><Settings2 />制作资料</div><button type="button" onClick={() => void navigate({ to: "/settings/storage" })}><span className={styles.icon}><FolderCog /></span><span><strong>数据目录</strong><small>{storage.isPending ? "正在读取目录…" : storage.data ? `${storage.data.workspace_count} 个项目 · ${storage.data.workspace_root}` : "管理项目保存位置"}</small></span><HardDrive className={styles.actionIcon} /></button></section><section><div className={styles.groupLabel}><Volume2 />声音与朗读</div><button type="button" onClick={() => void navigate({ to: "/settings/voices" })}><span className={styles.icon}><MicVocal /></span><span><strong>声音样本</strong><small>{voices.isPending ? "正在读取样本…" : `${readyVoiceCount ?? 0} 个可用声音 · 创建、试听与设为默认`}</small></span><Volume2 className={styles.actionIcon} /></button></section></div>
    {(storage.isPending || voices.isPending) && <p className={styles.loading}><LoaderCircle className={styles.spin} />正在同步本机设置状态…</p>}
  </section>;
}
