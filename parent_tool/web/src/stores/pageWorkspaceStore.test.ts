import { beforeEach, describe, expect, it } from "vitest";

import type { PagePlanEntry } from "../api/client";
import { usePageWorkspaceStore } from "./pageWorkspaceStore";

const entry = {
  source_pdf_page: 1,
  source_size_pt: { width: 800, height: 400 },
  detect: { suspect_split: true, confidence: 62, suggested_split_ratio: 0.48 },
  decision: {
    mode: "split_lr",
    split_ratio: 0.48,
    rotate: 0,
    crop_pct: { top: 0, right: 0, bottom: 0, left: 0 },
    confirmed: false,
  },
  outputs: [],
} as PagePlanEntry;

describe("page workspace store", () => {
  beforeEach(() => usePageWorkspaceStore.getState().hydrate([entry]));

  it("hydrates server decisions without marking them dirty", () => {
    const state = usePageWorkspaceStore.getState();
    expect(state.decisions[1].split_ratio).toBe(0.48);
    expect(state.dirty).toBe(false);
  });

  it("marks edited decisions dirty and can confirm every page", () => {
    const state = usePageWorkspaceStore.getState();
    state.updateDecision(1, { ...state.decisions[1], split_ratio: 0.52 });
    usePageWorkspaceStore.getState().confirmAll();
    expect(usePageWorkspaceStore.getState().decisions[1]).toMatchObject({
      split_ratio: 0.52,
      confirmed: true,
    });
    expect(usePageWorkspaceStore.getState().dirty).toBe(true);
  });
});
