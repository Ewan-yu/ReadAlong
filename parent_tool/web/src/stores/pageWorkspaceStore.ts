import { create } from "zustand";

import type { PageDecision, PagePlanEntry } from "../api/client";

export type PageTool = "select" | "pan" | "split" | "crop";

type PageWorkspaceState = {
  selectedSourcePage: number;
  tool: PageTool;
  zoom: number;
  pan: { x: number; y: number };
  showBboxes: boolean;
  decisions: Record<number, PageDecision>;
  dirty: boolean;
  hydrate: (entries: PagePlanEntry[]) => void;
  selectPage: (sourcePage: number) => void;
  setTool: (tool: PageTool) => void;
  setZoom: (zoom: number) => void;
  setPan: (pan: { x: number; y: number }) => void;
  toggleBboxes: () => void;
  updateDecision: (sourcePage: number, decision: PageDecision) => void;
  confirmAll: () => void;
};

export const usePageWorkspaceStore = create<PageWorkspaceState>((set) => ({
  selectedSourcePage: 1,
  tool: "select",
  zoom: 1,
  pan: { x: 0, y: 0 },
  showBboxes: true,
  decisions: {},
  dirty: false,
  hydrate: (entries) =>
    set((state) => ({
      selectedSourcePage: Math.min(
        Math.max(state.selectedSourcePage, 1),
        Math.max(entries.length, 1),
      ),
      decisions: Object.fromEntries(
        entries.map((entry) => [entry.source_pdf_page, structuredClone(entry.decision)]),
      ),
      dirty: false,
      tool: "select",
      zoom: 1,
      pan: { x: 0, y: 0 },
    })),
  selectPage: (selectedSourcePage) =>
    set({ selectedSourcePage, tool: "select", zoom: 1, pan: { x: 0, y: 0 } }),
  setTool: (tool) => set({ tool }),
  setZoom: (zoom) => set({ zoom }),
  setPan: (pan) => set({ pan }),
  toggleBboxes: () => set((state) => ({ showBboxes: !state.showBboxes })),
  updateDecision: (sourcePage, decision) =>
    set((state) => ({
      decisions: { ...state.decisions, [sourcePage]: decision },
      dirty: true,
    })),
  confirmAll: () =>
    set((state) => ({
      decisions: Object.fromEntries(
        Object.entries(state.decisions).map(([page, decision]) => [
          page,
          { ...decision, confirmed: true },
        ]),
      ),
      dirty: true,
    })),
}));
