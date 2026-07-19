import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import {
  AlertTriangle,
  ArrowRight,
  BookOpen,
  CircleAlert,
  Clock3,
  FileCheck2,
  FolderOpen,
  HardDrive,
  LoaderCircle,
  Plus,
  Search,
  Trash2,
  X,
} from "lucide-react";
import { useMemo, useState } from "react";

import { deleteWorkspace, type ApiRequestError, type WorkspaceSummary } from "../../api/client";
import { storageQuery, workspacesQuery } from "../../api/queries";
import styles from "./WorkspaceLibraryPage.module.css";

type Filter = "all" | "active" | "completed" | "attention";

const statusCopy: Record<WorkspaceSummary["lifecycle_status"], string> = {
  in_progress: "制作中",
  running: "处理中",
  failed: "需要处理",
  stale: "需要更新",
  completed: "已导出",
  corrupt: "数据异常",
};

const stepCopy: Record<WorkspaceSummary["current_step"], string> = {
  pages: "页面处理",
  ocr: "OCR 与句子",
  proofread: "OCR 与句子",
  audio: "语音生成",
  export: "导出资源包",
};

function bytes(value: number) {
  if (value < 1024 * 1024) return `${Math.max(1, value / 1024).toFixed(0)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function date(value: string) {
  return new Intl.DateTimeFormat("zh-CN", {
    month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit",
  }).format(new Date(value));
}

function matchesFilter(item: WorkspaceSummary, filter: Filter) {
  if (filter === "completed") return item.lifecycle_status === "completed";
  if (filter === "attention") return ["failed", "stale", "corrupt"].includes(item.lifecycle_status);
  if (filter === "active") return !["completed", "corrupt"].includes(item.lifecycle_status);
  return true;
}

export function WorkspaceLibraryPage() {
  const navigate = useNavigate();
  const client = useQueryClient();
  const workspaces = useQuery(workspacesQuery);
  const storage = useQuery(storageQuery);
  const [filter, setFilter] = useState<Filter>("all");
  const [search, setSearch] = useState("");
  const [confirmDelete, setConfirmDelete] = useState<string>();
  const deletion = useMutation({
    mutationFn: deleteWorkspace,
    onSuccess: async () => {
      setConfirmDelete(undefined);
      await Promise.all([
        client.invalidateQueries({ queryKey: ["books"] }),
        client.invalidateQueries({ queryKey: ["storage"] }),
      ]);
    },
  });
  const visible = useMemo(() => {
    const needle = search.trim().toLocaleLowerCase();
    return (workspaces.data?.workspaces ?? []).filter((item) =>
      matchesFilter(item, filter)
      && (!needle || `${item.display_name} ${item.source_filename ?? ""} ${item.book_id}`.toLocaleLowerCase().includes(needle)),
    );
  }, [filter, search, workspaces.data]);

  if (workspaces.isPending) {
    return <div className={styles.state}><LoaderCircle className={styles.spin} /><p>正在整理制作历史…</p></div>;
  }
  if (workspaces.isError) {
    const error = workspaces.error as ApiRequestError;
    return <div className={styles.state} role="alert"><CircleAlert /><h1>制作历史暂时无法打开</h1><p>{error.message}</p></div>;
  }

  const items = workspaces.data.workspaces;
  const completed = items.filter((item) => item.lifecycle_status === "completed").length;
  return (
    <section className={styles.page}>
      <header className={styles.header}>
        <div><p>本机制作资料库</p><h1>从上次停下的地方继续</h1><span>每一本绘本的页面、校对、声音和导出结果都保存在这里。</span></div>
        <button type="button" className={styles.create} onClick={() => void navigate({ to: "/books/new" })}><Plus />新建绘本</button>
      </header>

      <section className={styles.overview} aria-label="资料库概览">
        <div><BookOpen /><span><small>制作项目</small><strong>{items.length}</strong></span></div>
        <div><FileCheck2 /><span><small>已经导出</small><strong>{completed}</strong></span></div>
        <div><HardDrive /><span><small>工作区占用</small><strong>{bytes(workspaces.data.total_size_bytes)}</strong></span></div>
        <p><FolderOpen /><span>{storage.data?.workspace_root ?? "正在读取数据目录…"}</span></p>
      </section>

      <div className={styles.toolbar}>
        <label className={styles.search}><Search /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="搜索书名或文件名" /><span>{visible.length} 本</span></label>
        <div className={styles.filters} role="group" aria-label="筛选制作项目">
          {([['all', '全部'], ['active', '制作中'], ['completed', '已导出'], ['attention', '需处理']] as const).map(([value, label]) => (
            <button type="button" data-active={filter === value || undefined} onClick={() => setFilter(value)} key={value}>{label}</button>
          ))}
        </div>
      </div>

      {items.length === 0 ? (
        <div className={styles.empty}><BookOpen /><h2>从第一本绘本开始</h2><p>导入 PDF 后，即使中途关闭家长端，也能回到这里继续。</p><button type="button" onClick={() => void navigate({ to: "/books/new" })}><Plus />新建绘本</button></div>
      ) : visible.length === 0 ? (
        <div className={styles.noResults}><Search /><strong>没有符合条件的项目</strong><button type="button" onClick={() => { setSearch(""); setFilter("all"); }}>清除筛选</button></div>
      ) : (
        <div className={styles.list}>
          <div className={styles.listHead}><span>绘本</span><span>当前进度</span><span>内容</span><span>占用 / 更新</span><span>操作</span></div>
          {visible.map((item, index) => {
            const deleting = deletion.isPending && deletion.variables === item.book_id;
            const confirming = confirmDelete === item.book_id;
            return (
              <article className={styles.item} data-tone={item.lifecycle_status} key={item.book_id}>
                <div className={styles.identity}><span className={styles.index}>{String(index + 1).padStart(2, "0")}</span><div><strong>{item.display_name}</strong><small title={item.source_filename ?? item.book_id}>{item.source_filename ?? item.book_id}</small></div></div>
                <div className={styles.progressCell}><span className={styles.status} data-tone={item.lifecycle_status}>{["failed", "stale", "corrupt"].includes(item.lifecycle_status) && <AlertTriangle />}{statusCopy[item.lifecycle_status]}</span><strong>{stepCopy[item.current_step]}</strong><small>{item.completed_steps} / 5 步完成</small></div>
                <div className={styles.contents}><span>{item.page_count == null ? "--" : item.page_count} 页</span><span>{item.sentence_count == null ? "--" : item.sentence_count} 句</span></div>
                <div className={styles.storage}><strong>{bytes(item.size_bytes)}</strong><small><Clock3 />{date(item.updated_at)}</small></div>
                <div className={styles.actions}>
                  {confirming ? <div className={styles.confirm}><span>删除全部制作文件？</span><button type="button" onClick={() => setConfirmDelete(undefined)}><X />取消</button><button type="button" className={styles.danger} disabled={deleting} onClick={() => deletion.mutate(item.book_id)}>{deleting ? <LoaderCircle className={styles.spin} /> : <Trash2 />}确认删除</button></div> : <><button type="button" className={styles.continue} disabled={item.lifecycle_status === "corrupt"} onClick={() => void navigate({ href: item.continue_path })}>继续制作<ArrowRight /></button><button type="button" className={styles.remove} aria-label={`删除 ${item.display_name}`} onClick={() => setConfirmDelete(item.book_id)}><Trash2 /></button></>}
                  {deletion.isError && deletion.variables === item.book_id && <small className={styles.deleteError}>{(deletion.error as ApiRequestError).message}</small>}
                </div>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}

