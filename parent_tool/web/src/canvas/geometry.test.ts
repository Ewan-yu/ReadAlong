import { describe, expect, it } from "vitest";

import { fitRect, outputRectToSource, visibleSourceRects } from "./geometry";

const baseDecision = {
  mode: "keep" as const,
  split_ratio: null,
  rotate: 0 as const,
  crop_pct: { top: 10, right: 20, bottom: 10, left: 20 },
};

describe("page workspace geometry", () => {
  it("fits an image without changing its aspect ratio", () => {
    expect(fitRect(1000, 600, 800, 400, 20)).toEqual({
      x: -480,
      y: -240,
      width: 960,
      height: 480,
    });
  });

  it("maps a cropped output rectangle back to source coordinates", () => {
    const rect = outputRectToSource(
      { x: 0, y: 0, width: 1, height: 1 },
      baseDecision,
      "full",
    );
    expect(rect.x).toBeCloseTo(0.2);
    expect(rect.y).toBeCloseTo(0.1);
    expect(rect.width).toBeCloseTo(0.6);
    expect(rect.height).toBeCloseTo(0.8);
  });

  it("maps rotated right-page output back into its source half", () => {
    const rect = outputRectToSource(
      { x: 0, y: 0, width: 1, height: 1 },
      {
        mode: "split_lr",
        split_ratio: 0.4,
        rotate: 90,
        crop_pct: { top: 0, right: 0, bottom: 0, left: 0 },
      },
      "right",
    );
    expect(rect.x).toBeCloseTo(0.4);
    expect(rect.y).toBeCloseTo(0);
    expect(rect.width).toBeCloseTo(0.6);
    expect(rect.height).toBeCloseTo(1);
  });

  it("returns one crop outline for each split output", () => {
    const rects = visibleSourceRects({
      mode: "split_lr",
      split_ratio: 0.45,
      rotate: 0,
      crop_pct: { top: 5, right: 5, bottom: 5, left: 5 },
    });
    expect(rects).toHaveLength(2);
    expect(rects[0].x).toBeCloseTo(0.0225);
    expect(rects[1].x).toBeCloseTo(0.4775);
  });
});
