import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { AlertTriangle, CheckCircle2, Database, FolderInput, HardDrive, LoaderCircle, RefreshCw, RotateCcw } from "lucide-react";
import { useEffect, useState } from "react";

import { recalculateStorage, startStorageMigration, type ApiRequestError } from "../../api/client";
import { storageMigrationQuery, storageQuery } from "../../api/queries";
import styles from "./StorageSettingsPage.module.css";

function bytes(value: number) {
  if (value < 1024 * 1024) return `${Math.max(1, value / 1024).toFixed(0)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

export function StorageSettingsPage() {
  const client = useQueryClient();
  const storage = useQuery(storageQuery);
  const [target, setTarget] = useState("");
  const [migrationId, setMigrationId] = useState<string>();
  const migration = useQuery({ ...storageMigrationQuery(migrationId ?? ""), enabled: Boolean(migrationId) });
  const recalculate = useMutation({
    mutationFn: recalculateStorage,
    onSuccess: (data) => client.setQueryData(["storage"], data),
  });
  const move = useMutation({
    mutationFn: startStorageMigration,
    onSuccess: (data) => setMigrationId(data.migration_id),
  });
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
  </section>;
}
