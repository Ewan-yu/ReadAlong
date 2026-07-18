import { zodResolver } from "@hookform/resolvers/zod";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import {
  ArrowRight,
  Check,
  CircleAlert,
  Cloud,
  Cpu,
  Gauge,
  LoaderCircle,
  Package,
  RefreshCw,
} from "lucide-react";
import { useState } from "react";
import { useForm } from "react-hook-form";

import {
  createBook,
  runPageProcessing,
  type ApiRequestError,
  type JobSnapshot,
} from "../../api/client";
import { waitForJob } from "../../api/jobs";
import { capabilitiesQuery } from "../../api/queries";
import { FileDropField } from "./FileDropField";
import {
  createBookSchema,
  qualityPresets,
  valuesForPreset,
  type CreateBookValues,
  type QualityPreset,
} from "./form";
import styles from "./CreateBookPage.module.css";

function CapabilityPanel() {
  const { data, isPending, isError, refetch } = useQuery(capabilitiesQuery);
  const local = data?.filter((item) => item.group === "local") ?? [];
  const cloud = data?.filter((item) => item.group === "cloud") ?? [];

  const group = (title: string, items: typeof local, Icon: typeof Cpu) => (
    <section className={styles.capabilityGroup}>
      <h3><Icon />{title}</h3>
      {items.map((item) => (
        <div className={styles.capability} key={item.id}>
          <span className={styles.capabilityState} data-ready={item.available || undefined}>
            {item.available ? <Check /> : <CircleAlert />}
          </span>
          <span><strong>{item.name}</strong><small>{item.detail}</small></span>
        </div>
      ))}
    </section>
  );

  return (
    <aside className={styles.capabilities}>
      <div className={styles.panelHeading}>
        <div><span>环境检查</span><h2>所需能力</h2></div>
        <button type="button" onClick={() => void refetch()} aria-label="重新检测所需能力" disabled={isPending}>
          <RefreshCw className={isPending ? styles.spin : undefined} />
        </button>
      </div>
      {isPending && <p className={styles.panelMessage}>正在检查本机环境…</p>}
      {isError && <p className={styles.panelError}>暂时无法读取能力状态，可以继续导入 PDF 后重试。</p>}
      {!isPending && <>{group("本地能力", local, Cpu)}{group("云服务", cloud, Cloud)}</>}
      <p className={styles.capabilityNote}>页面处理只需要本机即可完成；OCR 与语音能力可在进入对应步骤前配置。</p>
    </aside>
  );
}

function ProgressBanner({ job }: { job: JobSnapshot }) {
  const percentage = Math.round(job.progress * 100);
  return (
    <div className={styles.progressBanner} role="status" aria-live="polite">
      <LoaderCircle className={styles.spin} />
      <div>
        <div className={styles.progressCopy}><strong>{job.message}</strong><span>{percentage}%</span></div>
        <div className={styles.progressTrack} aria-label="页面分析进度" aria-valuenow={percentage} role="progressbar">
          <span style={{ transform: `scaleX(${job.progress})` }} />
        </div>
      </div>
    </div>
  );
}

export function CreateBookPage() {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const [job, setJob] = useState<JobSnapshot>();
  const form = useForm<CreateBookValues>({
    resolver: zodResolver(createBookSchema),
    defaultValues: {
      pdf: undefined,
      originalAudio: undefined,
      quality: "clear",
      readingLongEdge: 2000,
      webpQuality: 82,
      splitDetectionEnabled: true,
    },
  });
  const pdf = form.watch("pdf");
  const originalAudio = form.watch("originalAudio");
  const quality = form.watch("quality");

  const mutation = useMutation({
    mutationFn: async (values: CreateBookValues) => {
      const state = await createBook(values.pdf, values.originalAudio);
      const run = await runPageProcessing(state.book_id, {
        quality: values.quality,
        reading_long_edge: values.readingLongEdge,
        webp_quality: values.webpQuality,
        split_detection_enabled: values.splitDetectionEnabled,
      });
      if (run.jobId) await waitForJob(run.jobId, setJob);
      return state.book_id;
    },
    onSuccess: async (bookId) => {
      await queryClient.invalidateQueries({ queryKey: ["books", bookId, "state"] });
      await navigate({ to: "/books/$bookId/pages", params: { bookId } });
    },
  });

  const selectPreset = (next: QualityPreset) => {
    const values = valuesForPreset(next);
    form.setValue("quality", values.quality, { shouldDirty: true });
    form.setValue("readingLongEdge", values.readingLongEdge, { shouldDirty: true });
    form.setValue("webpQuality", values.webpQuality, { shouldDirty: true });
  };

  const estimatedSize = pdf ? Math.max(pdf.size * 1.35, pdf.size) / 1024 / 1024 : undefined;
  const error = mutation.error as ApiRequestError | null;

  return (
    <div className={styles.page}>
      <header className={styles.pageHeader}>
        <div><p>新建加工项目</p><h1>把一本绘本，整理成可点读资源</h1></div>
        <span className={styles.headerIndex}>01</span>
      </header>

      {job && mutation.isPending && <ProgressBanner job={job} />}
      {error && (
        <div className={styles.errorBanner} role="alert">
          <CircleAlert />
          <div><strong>这次分析没有完成</strong><p>{error.message}</p></div>
        </div>
      )}

      <div className={styles.layout}>
        <form className={styles.form} onSubmit={form.handleSubmit((values) => mutation.mutate(values))}>
          <section className={styles.formSection}>
            <div className={styles.sectionNumber}>1</div>
            <div className={styles.sectionBody}>
              <FileDropField
                label="导入 PDF"
                hint="将绘本 PDF 拖到这里"
                accept={{ "application/pdf": [".pdf"] }}
                file={pdf}
                onChange={(file) => form.setValue("pdf", file as File, { shouldValidate: true })}
                error={form.formState.errors.pdf?.message}
              />
            </div>
          </section>

          <section className={styles.formSection}>
            <div className={styles.sectionNumber}>2</div>
            <div className={styles.sectionBody}>
              <FileDropField
                label="添加原音"
                hint="如有配套朗读，可添加 MP3"
                accept={{ "audio/mpeg": [".mp3"] }}
                file={originalAudio}
                optional
                onChange={(file) => form.setValue("originalAudio", file, { shouldValidate: true })}
                error={form.formState.errors.originalAudio?.message}
              />
            </div>
          </section>

          <section className={styles.formSection}>
            <div className={styles.sectionNumber}>3</div>
            <div className={styles.sectionBody}>
              <div className={styles.settingHeading}><div><strong>输出与质量</strong><small>可以先选预设，再微调数值</small></div><Gauge /></div>
              <div className={styles.presets} role="group" aria-label="输出质量预设">
                {(Object.keys(qualityPresets) as QualityPreset[]).map((key) => (
                  <button type="button" aria-pressed={quality === key} data-active={quality === key || undefined} onClick={() => selectPreset(key)} key={key}>
                    <strong>{qualityPresets[key].label}</strong><small>{qualityPresets[key].hint}</small>
                  </button>
                ))}
              </div>
              <div className={styles.settingsGrid}>
                <label><span>页面图片目标长边</span><span className={styles.inputWithUnit}><input type="number" {...form.register("readingLongEdge", { valueAsNumber: true })} /><b>px</b></span><small>建议 1500–2500</small></label>
                <label><span>WebP 质量</span><span className={styles.inputWithUnit}><input type="number" {...form.register("webpQuality", { valueAsNumber: true })} /><b>%</b></span><small>建议 70–90</small></label>
              </div>
              <label className={styles.checkbox}>
                <input type="checkbox" {...form.register("splitDetectionEnabled")} />
                <span><strong>自动识别双页跨页</strong><small>宽幅页面会给出拆分建议，并在下一步确认</small></span>
              </label>
            </div>
          </section>

          <footer className={styles.formFooter}>
            <button className={styles.primaryAction} type="submit" disabled={mutation.isPending}>
              {mutation.isPending ? <><LoaderCircle className={styles.spin} />正在分析页面</> : <>开始分析<ArrowRight /></>}
            </button>
            <p>完成后进入“页面处理”，确认拆分、旋转与裁边。</p>
          </footer>
        </form>

        <div className={styles.asideColumn}>
          <aside className={styles.overview}>
            <div className={styles.panelHeading}><div><span>当前资源</span><h2>资源包概览</h2></div><Package /></div>
            <dl>
              <div><dt>资源包格式</dt><dd>.readalongbook</dd></div>
              <div><dt>PDF 页数</dt><dd>分析后显示</dd></div>
              <div><dt>预计体积</dt><dd>{estimatedSize ? `约 ${estimatedSize.toFixed(1)} MB` : "-- MB"}</dd></div>
              <div><dt>原音</dt><dd>{originalAudio ? "已添加" : "未添加"}</dd></div>
            </dl>
          </aside>
          <CapabilityPanel />
        </div>
      </div>
    </div>
  );
}
