import createClient from "openapi-fetch";

import type { components, paths } from "./generated";

export type PipelineState = components["schemas"]["PipelineState"];
export type JobSnapshot = components["schemas"]["JobSnapshot"];
export type CapabilityStatus = components["schemas"]["CapabilityStatus"];
export type ApiErrorBody = components["schemas"]["ApiErrorResponse"];
export type PageWorkspaceResponse = components["schemas"]["PageWorkspaceResponse"];
export type PagePlanEntry = components["schemas"]["PagePlanEntry"];
export type PageDecision = components["schemas"]["PageDecision"];
export type PageProcessParams = components["schemas"]["PageProcessParams"];
export type OcrSentence = components["schemas"]["OcrSentence"];

export type ProofreadPage = { page_no: number; image: string; thumbnail: string };
export type ProofreadWorkspace = {
  pages_revision_id: string;
  ocr_revision_id: string;
  proofread_revision_id?: string | null;
  pages: ProofreadPage[];
  sentences: OcrSentence[];
  confirmed_pages: number[];
};

export type ProofreadCommit = {
  source_ocr_revision: string;
  sentences: OcrSentence[];
  confirmed_pages: number[];
};

export type AudioParams = {
  voice: { mode: "design" | "clone"; description: string; reference_wav_path?: string | null };
  opus_bitrate_kbps?: number;
  tempo?: number;
  language?: string;
  sentence_ids?: string[];
  base_audio_revision?: string | null;
};
export type AudioSentenceReport = {
  sentence_id: string; audio_path?: string | null; duration_seconds?: number | null;
  word_timing?: Array<{ word: string; t_start: number; t_end: number }> | null;
  provider?: "voxcpm" | null; suspect_tts: boolean; error_code?: string | null;
};
export type AudioWorkspace = {
  proofread_revision_id: string; audio_revision_id?: string | null; params: AudioParams;
  original_audio_path?: string | null;
  sentences: Array<{ sentence: OcrSentence; report?: AudioSentenceReport | null }>;
};
export type AudioWorkspaceSentence = AudioWorkspace["sentences"][number];
export type ExportWorkspace = {
  ready: boolean; suggested_title: string; export_revision_id?: string | null;
  checks: Array<{ id: string; label: string; status: "pass" | "warning" | "error"; detail: string }>;
  package: { filename: string; page_count: number; sentence_count: number; word_timing_sentence_count: number; audio_provider_counts: Record<string, number>; size_bytes?: number | null; sha256?: string | null };
};

const client = createClient<paths>({ baseUrl: "" });

export class ApiRequestError extends Error {
  readonly code: string;
  readonly details: unknown;

  constructor(body: Partial<ApiErrorBody> | undefined, fallback: string) {
    super(body?.message ?? fallback);
    this.name = "ApiRequestError";
    this.code = body?.code ?? "REQUEST_FAILED";
    this.details = body?.details;
  }
}

async function parseFetchError(response: Response, fallback: string): Promise<never> {
  let body: Partial<ApiErrorBody> | undefined;
  try {
    body = (await response.json()) as Partial<ApiErrorBody>;
  } catch {
    body = undefined;
  }
  throw new ApiRequestError(body, fallback);
}

export async function createBook(pdf: File, originalAudio?: File): Promise<PipelineState> {
  const body = new FormData();
  body.append("pdf", pdf);
  if (originalAudio) body.append("original_audio", originalAudio);
  const response = await fetch("/api/books", { method: "POST", body });
  if (!response.ok) await parseFetchError(response, "无法创建绘本工作区，请稍后重试。");
  return (await response.json()) as PipelineState;
}

export async function getBookState(bookId: string): Promise<PipelineState> {
  const { data, error } = await client.GET("/api/books/{book_id}/state", {
    params: { path: { book_id: bookId } },
  });
  if (!data) throw new ApiRequestError(error as Partial<ApiErrorBody>, "无法读取加工进度。");
  return data;
}

export async function getCapabilities(): Promise<CapabilityStatus[]> {
  const { data, error } = await client.GET("/api/capabilities");
  if (!data) throw new ApiRequestError(error as Partial<ApiErrorBody>, "无法检测本地能力。");
  return data.capabilities;
}

export type PageRunParams = {
  quality: "clear" | "balanced" | "compact";
  reading_long_edge: number;
  webp_quality: number;
  split_detection_enabled: boolean;
  page_decisions?: components["schemas"]["PageDecisionOverride"][];
  ocr_dpi?: number;
  detection_dpi?: number;
  thumbnail_long_edge?: number;
  thumbnail_quality?: number;
  wide_ratio_threshold?: number;
  center_window_start?: number;
  center_window_end?: number;
  confirmation_confidence?: number;
};

export async function runPageProcessing(
  bookId: string,
  params: PageRunParams,
): Promise<{ disposition: string; jobId?: string; state?: PipelineState }> {
  const { data, error } = await client.POST("/api/books/{book_id}/steps/{step_id}/run", {
    params: { path: { book_id: bookId, step_id: "pages" } },
    body: { params, force: false },
  });
  if (!data) throw new ApiRequestError(error as Partial<ApiErrorBody>, "页面分析未能启动。");
  if ("job_id" in data) {
    return { disposition: data.disposition, jobId: data.job_id };
  }
  return { disposition: data.disposition, state: data.state };
}

export async function runOcr(
  bookId: string,
): Promise<{ disposition: string; jobId?: string; state?: PipelineState }> {
  const { data, error } = await client.POST("/api/books/{book_id}/steps/{step_id}/run", {
    params: { path: { book_id: bookId, step_id: "ocr" } },
    body: { params: {}, force: false },
  });
  if (!data) throw new ApiRequestError(error as Partial<ApiErrorBody>, "OCR 识别未能启动。");
  if ("job_id" in data) {
    return { disposition: data.disposition, jobId: data.job_id };
  }
  return { disposition: data.disposition, state: data.state };
}

export async function getJob(jobId: string): Promise<JobSnapshot> {
  const { data, error } = await client.GET("/api/jobs/{job_id}", {
    params: { path: { job_id: jobId } },
  });
  if (!data) throw new ApiRequestError(error as Partial<ApiErrorBody>, "无法读取任务进度。");
  return data;
}

export async function getPageWorkspace(bookId: string): Promise<PageWorkspaceResponse> {
  const { data, error } = await client.GET("/api/books/{book_id}/pages/workspace", {
    params: { path: { book_id: bookId } },
  });
  if (!data) {
    throw new ApiRequestError(error as Partial<ApiErrorBody>, "无法读取页面处理结果。");
  }
  return data;
}

export async function getProofreadWorkspace(bookId: string): Promise<ProofreadWorkspace> {
  const response = await fetch(`/api/books/${encodeURIComponent(bookId)}/proofread/workspace`);
  if (!response.ok) await parseFetchError(response, "无法读取 OCR 校对工作区。");
  return (await response.json()) as ProofreadWorkspace;
}

export async function getAudioWorkspace(bookId: string): Promise<AudioWorkspace> {
  const response = await fetch(`/api/books/${encodeURIComponent(bookId)}/audio/workspace`);
  if (!response.ok) await parseFetchError(response, "无法读取语音生成工作区。");
  return (await response.json()) as AudioWorkspace;
}

export async function getExportWorkspace(bookId: string): Promise<ExportWorkspace> {
  const response = await fetch(`/api/books/${encodeURIComponent(bookId)}/export/workspace`);
  if (!response.ok) await parseFetchError(response, "无法读取资源导出工作区。");
  return (await response.json()) as ExportWorkspace;
}

export async function runExport(bookId: string, title?: string): Promise<{ disposition: string; jobId?: string; state?: PipelineState }> {
  const { data, error } = await client.POST("/api/books/{book_id}/steps/{step_id}/run", {
    params: { path: { book_id: bookId, step_id: "export" } }, body: { params: { title: title || null }, force: true },
  });
  if (!data) throw new ApiRequestError(error as Partial<ApiErrorBody>, "资源包导出未能启动。");
  if ("job_id" in data) return { disposition: data.disposition, jobId: data.job_id };
  return { disposition: data.disposition, state: data.state };
}

export async function runAudio(
  bookId: string,
  params: AudioParams,
): Promise<{ disposition: string; jobId?: string; state?: PipelineState }> {
  const { data, error } = await client.POST("/api/books/{book_id}/steps/{step_id}/run", {
    params: { path: { book_id: bookId, step_id: "audio" } }, body: { params, force: false },
  });
  if (!data) throw new ApiRequestError(error as Partial<ApiErrorBody>, "语音生成未能启动。");
  if ("job_id" in data) return { disposition: data.disposition, jobId: data.job_id };
  return { disposition: data.disposition, state: data.state };
}

export async function publishProofread(
  bookId: string,
  commit: ProofreadCommit,
): Promise<{ disposition: string; jobId?: string; state?: PipelineState }> {
  const response = await fetch(`/api/books/${encodeURIComponent(bookId)}/proofread/publish`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(commit),
  });
  if (!response.ok) await parseFetchError(response, "校对结果没有发布成功。");
  const data = (await response.json()) as { disposition: string; job_id?: string; state?: PipelineState };
  return { disposition: data.disposition, jobId: data.job_id, state: data.state };
}

export async function checkProofreadText(bookId: string, text: string): Promise<OcrSentence["suspect_words"]> {
  const response = await fetch(`/api/books/${encodeURIComponent(bookId)}/proofread/check-text`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text }),
  });
  if (!response.ok) await parseFetchError(response, "拼写检查暂时不可用。");
  const data = (await response.json()) as { suspect_words: OcrSentence["suspect_words"] };
  return data.suspect_words;
}

export function sourcePagePreviewUrl(bookId: string, sourcePage: number, maxEdge = 1800): string {
  return `/api/books/${encodeURIComponent(bookId)}/pages/source/${sourcePage}.webp?max_edge=${maxEdge}`;
}

export function pageAssetUrl(bookId: string, revisionId: string, assetPath: string): string {
  const encodedPath = assetPath.split("/").map(encodeURIComponent).join("/");
  return `/api/books/${encodeURIComponent(bookId)}/pages/revisions/${encodeURIComponent(revisionId)}/assets/${encodedPath}`;
}

export function audioAssetUrl(bookId: string, revisionId: string, assetPath: string): string {
  const encodedPath = assetPath.split("/").map(encodeURIComponent).join("/");
  return `/api/books/${encodeURIComponent(bookId)}/audio/revisions/${encodeURIComponent(revisionId)}/assets/${encodedPath}`;
}

export function exportDownloadUrl(bookId: string, revisionId: string): string {
  return `/api/books/${encodeURIComponent(bookId)}/export/revisions/${encodeURIComponent(revisionId)}/download`;
}
