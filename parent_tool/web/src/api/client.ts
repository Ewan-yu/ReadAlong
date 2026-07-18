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

export function sourcePagePreviewUrl(bookId: string, sourcePage: number, maxEdge = 1800): string {
  return `/api/books/${encodeURIComponent(bookId)}/pages/source/${sourcePage}.webp?max_edge=${maxEdge}`;
}

export function pageAssetUrl(bookId: string, revisionId: string, assetPath: string): string {
  const encodedPath = assetPath.split("/").map(encodeURIComponent).join("/");
  return `/api/books/${encodeURIComponent(bookId)}/pages/revisions/${encodeURIComponent(revisionId)}/assets/${encodedPath}`;
}
