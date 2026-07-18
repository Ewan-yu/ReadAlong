import { z } from "zod";

export const qualityPresets = {
  clear: { readingLongEdge: 2000, webpQuality: 82, label: "清晰", hint: "细节优先" },
  balanced: { readingLongEdge: 1600, webpQuality: 78, label: "均衡", hint: "画质与体积" },
  compact: { readingLongEdge: 1200, webpQuality: 72, label: "小体积", hint: "便于传输" },
} as const;

export type QualityPreset = keyof typeof qualityPresets;

export const createBookSchema = z.object({
  pdf: z.custom<File>((value) => value instanceof File, "请选择要加工的 PDF 文件。"),
  originalAudio: z.custom<File>((value) => value instanceof File).optional(),
  quality: z.enum(["clear", "balanced", "compact"]),
  readingLongEdge: z.number().int().min(800, "长边不能小于 800 px。").max(4000, "长边不能超过 4000 px。"),
  webpQuality: z.number().int().min(1).max(100),
  splitDetectionEnabled: z.boolean(),
});

export type CreateBookValues = z.infer<typeof createBookSchema>;

export function valuesForPreset(quality: QualityPreset) {
  const preset = qualityPresets[quality];
  return { quality, readingLongEdge: preset.readingLongEdge, webpQuality: preset.webpQuality };
}
