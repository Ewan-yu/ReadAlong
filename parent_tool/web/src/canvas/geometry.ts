export type NormalizedPoint = { x: number; y: number };
export type NormalizedRect = { x: number; y: number; width: number; height: number };
export type PixelRect = NormalizedRect;
export type CropPercent = { top: number; right: number; bottom: number; left: number };
export type PageRegion = "full" | "left" | "right";
export type GeometryDecision = {
  mode: "keep" | "split_lr";
  split_ratio?: number | null;
  rotate: 0 | 90 | 180 | 270;
  crop_pct?: CropPercent;
};

export function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

export function fitRect(
  containerWidth: number,
  containerHeight: number,
  imageWidth: number,
  imageHeight: number,
  padding = 0,
): PixelRect {
  const availableWidth = Math.max(1, containerWidth - padding * 2);
  const availableHeight = Math.max(1, containerHeight - padding * 2);
  const scale = Math.min(availableWidth / imageWidth, availableHeight / imageHeight);
  const width = imageWidth * scale;
  const height = imageHeight * scale;
  return { x: -width / 2, y: -height / 2, width, height };
}

export function normalizedRectToPixels(rect: NormalizedRect, image: PixelRect): PixelRect {
  return {
    x: image.x + rect.x * image.width,
    y: image.y + rect.y * image.height,
    width: rect.width * image.width,
    height: rect.height * image.height,
  };
}

function inverseRotate(point: NormalizedPoint, rotate: GeometryDecision["rotate"]): NormalizedPoint {
  if (rotate === 90) return { x: point.y, y: 1 - point.x };
  if (rotate === 180) return { x: 1 - point.x, y: 1 - point.y };
  if (rotate === 270) return { x: 1 - point.y, y: point.x };
  return point;
}

export function outputPointToSource(
  point: NormalizedPoint,
  decision: GeometryDecision,
  region: PageRegion,
): NormalizedPoint {
  const crop = decision.crop_pct ?? { top: 0, right: 0, bottom: 0, left: 0 };
  const rotated = {
    x: crop.left / 100 + point.x * (1 - (crop.left + crop.right) / 100),
    y: crop.top / 100 + point.y * (1 - (crop.top + crop.bottom) / 100),
  };
  const local = inverseRotate(rotated, decision.rotate);
  if (decision.mode === "keep" || region === "full") return local;
  const split = decision.split_ratio ?? 0.5;
  if (region === "left") return { x: local.x * split, y: local.y };
  return { x: split + local.x * (1 - split), y: local.y };
}

export function outputRectToSource(
  rect: NormalizedRect,
  decision: GeometryDecision,
  region: PageRegion,
): NormalizedRect {
  const corners = [
    outputPointToSource({ x: rect.x, y: rect.y }, decision, region),
    outputPointToSource({ x: rect.x + rect.width, y: rect.y }, decision, region),
    outputPointToSource({ x: rect.x, y: rect.y + rect.height }, decision, region),
    outputPointToSource(
      { x: rect.x + rect.width, y: rect.y + rect.height },
      decision,
      region,
    ),
  ];
  const xs = corners.map((point) => point.x);
  const ys = corners.map((point) => point.y);
  const left = clamp(Math.min(...xs), 0, 1);
  const top = clamp(Math.min(...ys), 0, 1);
  const right = clamp(Math.max(...xs), 0, 1);
  const bottom = clamp(Math.max(...ys), 0, 1);
  return { x: left, y: top, width: right - left, height: bottom - top };
}

export function visibleSourceRects(decision: GeometryDecision): NormalizedRect[] {
  const regions: PageRegion[] = decision.mode === "split_lr" ? ["left", "right"] : ["full"];
  return regions.map((region) =>
    outputRectToSource({ x: 0, y: 0, width: 1, height: 1 }, decision, region),
  );
}
