import { ApiRequestError, getJob, type JobSnapshot } from "./client";

const terminal = new Set(["succeeded", "failed", "cancelled", "interrupted"]);

function settle(snapshot: JobSnapshot): JobSnapshot {
  if (snapshot.status === "succeeded") return snapshot;
  throw new ApiRequestError(snapshot.error ?? undefined, snapshot.message || "处理任务未完成。");
}

export async function waitForJob(
  jobId: string,
  onUpdate: (snapshot: JobSnapshot) => void,
): Promise<JobSnapshot> {
  const initial = await getJob(jobId);
  onUpdate(initial);
  if (terminal.has(initial.status)) return settle(initial);

  return new Promise((resolve, reject) => {
    let closed = false;
    let polling = false;
    const source = new EventSource(`/api/jobs/${encodeURIComponent(jobId)}/events`);

    const finish = (snapshot: JobSnapshot) => {
      if (closed) return;
      closed = true;
      source.close();
      try {
        resolve(settle(snapshot));
      } catch (error) {
        reject(error);
      }
    };

    const receive = (event: MessageEvent<string>) => {
      const snapshot = JSON.parse(event.data) as JobSnapshot;
      onUpdate(snapshot);
      if (terminal.has(snapshot.status)) finish(snapshot);
    };

    ["snapshot", "progress", "succeeded", "failed", "cancelled", "interrupted"].forEach(
      (name) => source.addEventListener(name, receive as EventListener),
    );

    const poll = async () => {
      if (closed) return;
      try {
        const snapshot = await getJob(jobId);
        onUpdate(snapshot);
        if (terminal.has(snapshot.status)) {
          finish(snapshot);
          return;
        }
      } catch (error) {
        if (closed) return;
        if (error instanceof ApiRequestError && error.code === "JOB_NOT_FOUND") {
          closed = true;
          reject(error);
          return;
        }
      }
      window.setTimeout(poll, 2000);
    };

    source.onerror = () => {
      source.close();
      if (!polling) {
        polling = true;
        void poll();
      }
    };
  });
}
