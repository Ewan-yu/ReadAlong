import { useEffect } from "react";
import { useBlocker } from "@tanstack/react-router";

/** Keeps unpublished workbench edits from vanishing silently.
 *
 *  Route changes get a confirmation, reloads/close get the browser's own
 *  leave prompt (enableBeforeUnload). Publishing or explicitly discarding
 *  clears the dirty flag and with it the guard. */
export function useDraftGuard(dirty: boolean) {
  const blocker = useBlocker({
    shouldBlockFn: () => dirty,
    enableBeforeUnload: () => dirty,
    withResolver: true,
  });

  useEffect(() => {
    if (blocker.status !== "blocked") return;
    const leave = window.confirm(
      "当前有未发布的编辑，离开后会丢失这些修改。\n确定要离开吗？",
    );
    if (leave) blocker.proceed?.();
    else blocker.reset?.();
  }, [blocker]);
}
