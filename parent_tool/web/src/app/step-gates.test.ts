import { describe, expect, it } from "vitest";

import type { PipelineState } from "../api/client";
import { isStepUnlocked } from "./step-gates";

function state(statuses: Partial<Record<"pages" | "ocr" | "proofread" | "audio" | "export", string>>) {
  return { steps: Object.fromEntries(Object.entries(statuses).map(([key, status]) => [key, { status }])) } as PipelineState;
}

describe("workflow gates", () => {
  it("unlocks pages for a newly created book but keeps downstream steps closed", () => {
    const value = state({ pages: "pending", proofread: "pending", audio: "pending" });
    expect(isStepUnlocked(value, 2)).toBe(true);
    expect(isStepUnlocked(value, 3)).toBe(false);
  });

  it("allows inspecting stale prerequisites while protecting later steps", () => {
    const value = state({ pages: "stale", proofread: "done", audio: "pending" });
    expect(isStepUnlocked(value, 3)).toBe(true);
    expect(isStepUnlocked(value, 4)).toBe(true);
    expect(isStepUnlocked(value, 5)).toBe(false);
  });
});
