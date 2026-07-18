import { Group, Image as KonvaImage, Layer, Rect, Stage } from "react-konva";
import { useEffect, useMemo, useRef, useState } from "react";

import type { OcrSentence } from "../../api/client";
import { clampBox } from "./draft";
import styles from "./ProofreadWorkspace.module.css";

type Tool = "select" | "draw" | "split";

type Props = {
  imageUrl: string;
  sentences: OcrSentence[];
  selectedIds: string[];
  tool: Tool;
  onSelect: (id: string, additive: boolean) => void;
  onDraw: (box: OcrSentence["bbox"], splitSourceId?: string) => void;
};

function useLoadedImage(url: string) {
  const [image, setImage] = useState<HTMLImageElement>();
  useEffect(() => {
    const next = new window.Image();
    next.decoding = "async";
    next.src = url;
    next.onload = () => setImage(next);
    return () => { next.onload = null; };
  }, [url]);
  return image;
}

function useContainerSize(ref: React.RefObject<HTMLDivElement | null>) {
  const [size, setSize] = useState({ width: 760, height: 600 });
  useEffect(() => {
    if (!ref.current) return undefined;
    const observer = new ResizeObserver(([entry]) => setSize({
      width: Math.max(360, Math.round(entry.contentRect.width)),
      height: Math.max(320, Math.round(entry.contentRect.height)),
    }));
    observer.observe(ref.current);
    return () => observer.disconnect();
  }, [ref]);
  return size;
}

export function ProofreadStage({ imageUrl, sentences, selectedIds, tool, onSelect, onDraw }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const image = useLoadedImage(imageUrl);
  const size = useContainerSize(ref);
  const start = useRef<{ x: number; y: number } | undefined>(undefined);
  const [draft, setDraft] = useState<OcrSentence["bbox"]>();
  const fit = useMemo(() => {
    const scale = Math.min((size.width - 40) / (image?.width ?? 1), (size.height - 40) / (image?.height ?? 1));
    const width = (image?.width ?? 1) * scale;
    const height = (image?.height ?? 1) * scale;
    return { x: (size.width - width) / 2, y: (size.height - height) / 2, width, height };
  }, [image, size]);
  const selected = selectedIds[0];

  const positionToBox = (x: number, y: number): OcrSentence["bbox"] => clampBox({
    x: (Math.min(x, start.current?.x ?? x) - fit.x) / fit.width,
    y: (Math.min(y, start.current?.y ?? y) - fit.y) / fit.height,
    width: Math.abs(x - (start.current?.x ?? x)) / fit.width,
    height: Math.abs(y - (start.current?.y ?? y)) / fit.height,
  });

  return (
    <div ref={ref} className={styles.stage} aria-label="阅读页文字框画布">
      {!image && <span className={styles.stageLoading}>正在载入阅读页…</span>}
      <Stage
        width={size.width}
        height={size.height}
        onMouseDown={(event) => {
          if (tool === "select") return;
          const point = event.target.getStage()?.getPointerPosition();
          if (!point || point.x < fit.x || point.y < fit.y || point.x > fit.x + fit.width || point.y > fit.y + fit.height) return;
          start.current = point;
          setDraft({ x: (point.x - fit.x) / fit.width, y: (point.y - fit.y) / fit.height, width: 0.01, height: 0.01 });
        }}
        onMouseMove={(event) => {
          if (!start.current) return;
          const point = event.target.getStage()?.getPointerPosition();
          if (point) setDraft(positionToBox(point.x, point.y));
        }}
        onMouseUp={(event) => {
          if (!start.current || !draft) return;
          const point = event.target.getStage()?.getPointerPosition();
          const box = point ? positionToBox(point.x, point.y) : draft;
          start.current = undefined;
          setDraft(undefined);
          if (box.width > 0.015 && box.height > 0.015) onDraw(box, tool === "split" ? selected : undefined);
        }}
      >
        <Layer>
          {image && <KonvaImage image={image} {...fit} listening={false} />}
          <Group>
            {sentences.map((sentence) => {
              const active = selectedIds.includes(sentence.id);
              const review = sentence.status === "needs_review";
              return <Rect
                key={sentence.id}
                x={fit.x + sentence.bbox.x * fit.width}
                y={fit.y + sentence.bbox.y * fit.height}
                width={sentence.bbox.width * fit.width}
                height={sentence.bbox.height * fit.height}
                stroke={active ? "#087f7b" : review ? "#b66118" : "rgba(8, 127, 123, .75)"}
                strokeWidth={active ? 3 : 1.25}
                dash={review ? [6, 4] : undefined}
                fill={active ? "rgba(8,127,123,.13)" : "rgba(8,127,123,.035)"}
                onClick={(event) => { event.cancelBubble = true; onSelect(sentence.id, event.evt.shiftKey || event.evt.ctrlKey || event.evt.metaKey); }}
                onTap={(event) => { event.cancelBubble = true; onSelect(sentence.id, false); }}
              />;
            })}
            {draft && <Rect x={fit.x + draft.x * fit.width} y={fit.y + draft.y * fit.height} width={draft.width * fit.width} height={draft.height * fit.height} stroke="#087f7b" dash={[6, 4]} strokeWidth={2} />}
          </Group>
        </Layer>
      </Stage>
    </div>
  );
}
