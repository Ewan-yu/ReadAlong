import type { PipelineState } from "../api/client";

export type WorkflowStep = 1 | 2 | 3 | 4 | 5;

const ready = (status: string | undefined) => status === "done" || status === "stale";

export function isStepUnlocked(state: PipelineState | undefined, step: WorkflowStep): boolean {
  if (step === 1) return true;
  if (!state) return false;
  if (step === 2) return true;
  if (step === 3) return ready(state.steps.pages?.status);
  if (step === 4) return ready(state.steps.proofread?.status);
  return ready(state.steps.audio?.status);
}

export function isStepComplete(state: PipelineState | undefined, step: WorkflowStep): boolean {
  if (!state || step === 1) return false;
  const key = ({ 2: "pages", 3: "proofread", 4: "audio", 5: "export" } as const)[step];
  return state.steps[key]?.status === "done";
}
