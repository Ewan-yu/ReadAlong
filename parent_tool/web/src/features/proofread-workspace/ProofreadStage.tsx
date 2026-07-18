import { Group, Image as KonvaImage, Layer, Rect, Stage } from "react-konva";
import { Maximize2, ZoomIn, ZoomOut } from "lucide-react";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";

import type { OcrSentence } from "../../api/client";
import { clamp, fitRect } from "../../canvas/geometry";
import { clampBox } from "./draft";
import styles from "./ProofreadWorkspace.module.css";

type Tool = "select" | "pan" | "draw" | "split";

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
  const [size, setSize] = useState({ width: 800, height: 620 });
  useLayoutEffect(() => {
    if (!ref.current) return undefined;
    const update = (width: number, height: number) => setSize({
      width: Math.max(320, Math.round(width)),
      height: Math.max(280, Math.round(height)),
    });
    const observer = new ResizeObserver(([entry]) => update(entry.contentRect.width, entry.contentRect.height));
    observer.observe(ref.current);
    const rect = ref.current.getBoundingClientRect();
    update(rect.width, rect.height);
    return () => observer.disconnect();
  }, [ref]);
  return size;
}

export function ProofreadStage({ imageUrl, sentences, selectedIds, tool, onSelect, onDraw }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const image = useLoadedImage(imageUrl);
  const size = useContainerSize(ref);
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const start = useRef<{ x: number; y: number } | undefined>(undefined);
  const [draft, setDraft] = useState<OcrSentence["bbox"]>();
  const imageRect = useMemo(
    () => fitRect(size.width, size.height, image?.width ?? 1, image?.height ?? 1, 36),
    [image, size],
  );
  const groupX = size.width / 2 + pan.x;
  const groupY = size.height / 2 + pan.y;
  useEffect(() => { setZoom(1); setPan({ x: 0, y: 0 }); }, [imageUrl]);
  const selected = selectedIds[0];

  const positionToBox = (x: number, y: number): OcrSentence["bbox"] => clampBox({
    x: (Math.min(x, start.current?.x ?? x) / zoom - groupX / zoom - imageRect.x) / imageRect.width,
    y: (Math.min(y, start.current?.y ?? y) / zoom - groupY / zoom - imageRect.y) / imageRect.height,
    width: Math.abs(x - (start.current?.x ?? x)) / zoom / imageRect.width,
    height: Math.abs(y - (start.current?.y ?? y)) / zoom / imageRect.height,
  });

  return (
    <div className={styles.stageShell}>
      <div ref={ref} className={styles.stage} aria-label="阅读页文字框画布">
        {!image && <span className={styles.stageLoading}>正在载入阅读页…</span>}
        <Stage
          width={size.width}
          height={size.height}
          onWheel={(event) => {
            event.evt.preventDefault();
            setZoom((value) => clamp(value * (event.evt.deltaY > 0 ? 0.9 : 1.1), 0.6, 3));
          }}
          onMouseDown={(event) => {
            if (tool === "select" || tool === "pan") return;
            const point = event.target.getStage()?.getPointerPosition();
            if (!point) return;
            const localX = (point.x - groupX) / zoom;
            const localY = (point.y - groupY) / zoom;
            if (localX < imageRect.x || localY < imageRect.y || localX > imageRect.x + imageRect.width || localY > imageRect.y + imageRect.height) return;
            start.current = point;
            setDraft({ x: (localX - imageRect.x) / imageRect.width, y: (localY - imageRect.y) / imageRect.height, width: 0.01, height: 0.01 });
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
            <Group
              x={groupX}
              y={groupY}
              scaleX={zoom}
              scaleY={zoom}
              draggable={tool === "pan"}
              onDragEnd={(event) => setPan({ x: event.target.x() - size.width / 2, y: event.target.y() - size.height / 2 })}
            >
              {image && <KonvaImage image={image} {...imageRect} listening={false} />}
              {sentences.map((sentence) => {
                const active = selectedIds.includes(sentence.id);
                const review = sentence.status === "needs_review";
                return <Rect
                  key={sentence.id}
                  x={imageRect.x + sentence.bbox.x * imageRect.width}
                  y={imageRect.y + sentence.bbox.y * imageRect.height}
                  width={sentence.bbox.width * imageRect.width}
                  height={sentence.bbox.height * imageRect.height}
                  stroke={active ? "#087f7b" : review ? "#b66118" : "rgba(8, 127, 123, .75)"}
                  strokeWidth={(active ? 3 : 1.25) / zoom}
                  dash={review ? [6, 4] : undefined}
                  fill={active ? "rgba(8,127,123,.13)" : "rgba(8,127,123,.035)"}
                  onClick={(event) => { event.cancelBubble = true; onSelect(sentence.id, event.evt.shiftKey || event.evt.ctrlKey || event.evt.metaKey); }}
                  onTap={(event) => { event.cancelBubble = true; onSelect(sentence.id, false); }}
                />;
              })}
              {draft && <Rect x={imageRect.x + draft.x * imageRect.width} y={imageRect.y + draft.y * imageRect.height} width={draft.width * imageRect.width} height={draft.height * imageRect.height} stroke="#087f7b" dash={[6 / zoom, 4 / zoom]} strokeWidth={2 / zoom} />}
            </Group>
          </Layer>
        </Stage>
      </div>
      <div className={styles.canvasControls} aria-label="画布缩放控制">
        <button type="button" aria-label="缩小画布" disabled={zoom <= 0.6} onClick={() => setZoom((value) => clamp(value - 0.2, 0.6, 3))}><ZoomOut /></button>
        <span>{Math.round(zoom * 100)}%</span>
        <button type="button" aria-label="放大画布" disabled={zoom >= 3} onClick={() => setZoom((value) => clamp(value + 0.2, 0.6, 3))}><ZoomIn /></button>
        <button type="button" onClick={() => { setZoom(1); setPan({ x: 0, y: 0 }); }}><Maximize2 />适合画布</button>
      </div>
    </div>
  );
}
