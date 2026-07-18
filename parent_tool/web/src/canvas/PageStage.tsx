import Konva from "konva";
import { Image as KonvaImage, Layer, Group, Line, Rect, Circle, Stage } from "react-konva";
import { useEffect, useMemo, useRef, useState } from "react";

import type { OcrSentence, PageDecision, PagePlanEntry } from "../api/client";
import { usePageWorkspaceStore } from "../stores/pageWorkspaceStore";
import {
  clamp,
  fitRect,
  normalizedRectToPixels,
  outputRectToSource,
  visibleSourceRects,
} from "./geometry";
import styles from "./PageStage.module.css";

type Props = {
  imageUrl: string;
  entry: PagePlanEntry;
  decision: PageDecision;
  sentences: OcrSentence[];
  bboxesStale: boolean;
  onDecisionChange: (decision: PageDecision) => void;
};

function useLoadedImage(url: string) {
  const [image, setImage] = useState<HTMLImageElement>();
  useEffect(() => {
    const next = new window.Image();
    next.decoding = "async";
    next.src = url;
    next.onload = () => setImage(next);
    return () => {
      next.onload = null;
    };
  }, [url]);
  return image;
}

function useContainerSize(ref: React.RefObject<HTMLDivElement | null>) {
  const [size, setSize] = useState({ width: 800, height: 620 });
  useEffect(() => {
    if (!ref.current) return undefined;
    const observer = new ResizeObserver(([entry]) => {
      setSize({
        width: Math.max(320, Math.round(entry.contentRect.width)),
        height: Math.max(280, Math.round(entry.contentRect.height)),
      });
    });
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, [ref]);
  return size;
}

export function PageStage({
  imageUrl,
  entry,
  decision,
  sentences,
  bboxesStale,
  onDecisionChange,
}: Props) {
  const containerRef = useRef<HTMLDivElement>(null);
  const image = useLoadedImage(imageUrl);
  const size = useContainerSize(containerRef);
  const { tool, zoom, pan, showBboxes, setZoom, setPan } = usePageWorkspaceStore();
  const imageRect = useMemo(
    () => fitRect(size.width, size.height, image?.width ?? 1, image?.height ?? 1, 36),
    [image, size],
  );
  const palette = useMemo(() => {
    const css = getComputedStyle(document.documentElement);
    return {
      primary: css.getPropertyValue("--color-primary").trim() || "#087f7b",
      warning: css.getPropertyValue("--color-warning").trim() || "#b66118",
      surface: css.getPropertyValue("--color-surface").trim() || "#fffdf7",
    };
  }, []);

  const bboxRects = useMemo(() => {
    if (!showBboxes || bboxesStale) return [];
    return entry.outputs.flatMap((output) =>
      sentences
        .filter((sentence) => sentence.page_no === output.page_no)
        .map((sentence) => ({
          id: sentence.id,
          rect: normalizedRectToPixels(
            outputRectToSource(
              {
                x: sentence.bbox.x,
                y: sentence.bbox.y,
                width: sentence.bbox.width,
                height: sentence.bbox.height,
              },
              decision,
              output.region,
            ),
            imageRect,
          ),
          needsReview: sentence.status === "needs_review",
        })),
    );
  }, [bboxesStale, decision, entry.outputs, imageRect, sentences, showBboxes]);

  const cropRects = useMemo(
    () => visibleSourceRects(decision).map((rect) => normalizedRectToPixels(rect, imageRect)),
    [decision, imageRect],
  );
  const splitX = imageRect.x + imageRect.width * (decision.split_ratio ?? 0.5);

  const changeSplit = (target: Konva.Node) => {
    const x = clamp(target.x(), imageRect.x + imageRect.width * 0.1, imageRect.x + imageRect.width * 0.9);
    target.x(x);
    target.y(0);
    onDecisionChange({
      ...decision,
      split_ratio: Number(((x - imageRect.x) / imageRect.width).toFixed(4)),
      confirmed: false,
    });
  };

  return (
    <div
      ref={containerRef}
      className={styles.stage}
      role="img"
      aria-label={`源 PDF 第 ${entry.source_pdf_page} 页页面处理画布。所有操作均可在右侧数值面板完成。`}
    >
      {!image && <div className={styles.loading}>正在展开源页预览…</div>}
      <Stage
        width={size.width}
        height={size.height}
        onWheel={(event) => {
          event.evt.preventDefault();
          setZoom(clamp(zoom * (event.evt.deltaY > 0 ? 0.9 : 1.1), 0.6, 3));
        }}
      >
        <Layer>
          <Group
            x={size.width / 2 + pan.x}
            y={size.height / 2 + pan.y}
            scaleX={zoom}
            scaleY={zoom}
            draggable={tool === "pan"}
            onDragEnd={(event) => setPan({
              x: event.target.x() - size.width / 2,
              y: event.target.y() - size.height / 2,
            })}
          >
            {image && (
              <KonvaImage
                image={image}
                x={imageRect.x}
                y={imageRect.y}
                width={imageRect.width}
                height={imageRect.height}
                shadowColor="rgba(28, 52, 50, 0.18)"
                shadowBlur={18}
                shadowOffsetY={8}
                listening={false}
              />
            )}

            {bboxRects.map(({ id, rect, needsReview }) => (
              <Rect
                key={id}
                {...rect}
                stroke={needsReview ? palette.warning : palette.primary}
                strokeWidth={1.5 / zoom}
                dash={needsReview ? [6 / zoom, 4 / zoom] : undefined}
                fill={needsReview ? "rgba(207, 111, 32, 0.06)" : "rgba(8, 127, 123, 0.035)"}
                listening={false}
              />
            ))}

            {tool === "crop" && cropRects.map((rect, index) => (
              <Group key={`${rect.x}-${index}`} listening={false}>
                <Rect
                  {...rect}
                  stroke={palette.primary}
                  strokeWidth={2 / zoom}
                  dash={[9 / zoom, 5 / zoom]}
                />
                {[
                  [rect.x, rect.y],
                  [rect.x + rect.width, rect.y],
                  [rect.x, rect.y + rect.height],
                  [rect.x + rect.width, rect.y + rect.height],
                ].map(([x, y]) => (
                  <Circle
                    key={`${x}-${y}`}
                    x={x}
                    y={y}
                    radius={5 / zoom}
                    fill={palette.surface}
                    stroke={palette.primary}
                    strokeWidth={2 / zoom}
                  />
                ))}
              </Group>
            ))}

            {decision.mode === "split_lr" && (
              <Group
                x={splitX}
                draggable={tool === "split"}
                onDragMove={(event) => changeSplit(event.target)}
                onDragEnd={(event) => changeSplit(event.target)}
              >
                <Line
                  points={[0, imageRect.y, 0, imageRect.y + imageRect.height]}
                  stroke={palette.primary}
                  strokeWidth={(tool === "split" ? 2.5 : 1.5) / zoom}
                  dash={[8 / zoom, 6 / zoom]}
                  listening={false}
                />
                {tool === "split" && (
                  <Circle
                    y={0}
                    radius={13 / zoom}
                    fill={palette.surface}
                    stroke={palette.primary}
                    strokeWidth={2 / zoom}
                  />
                )}
              </Group>
            )}
          </Group>
        </Layer>
      </Stage>
    </div>
  );
}
