import type { QueryClient } from "@tanstack/react-query";
import {
  createRootRouteWithContext,
  createRoute,
  createRouter,
  lazyRouteComponent,
  redirect,
} from "@tanstack/react-router";

import { bookStateQuery } from "../api/queries";
import { CreateBookPage } from "../features/create-book/CreateBookPage";
import { StepPlaceholder } from "../features/placeholders/StepPlaceholder";
import { AppShell } from "./AppShell";
import { isStepUnlocked, type WorkflowStep } from "./step-gates";

type RouterContext = { queryClient: QueryClient };

const rootRoute = createRootRouteWithContext<RouterContext>()({ component: AppShell });

const indexRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  beforeLoad: () => { throw redirect({ to: "/books/new" }); },
});

const newBookRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/new",
  component: CreateBookPage,
});

function guardStep(step: WorkflowStep) {
  return async ({ context, params }: { context: RouterContext; params: Record<string, string> }) => {
      const bookId = (params as { bookId: string }).bookId;
      const state = await context.queryClient.ensureQueryData(bookStateQuery(bookId));
      if (!isStepUnlocked(state, step)) {
        throw redirect({ href: `/books/${bookId}/pages` });
      }
  };
}

const pagesRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/$bookId/pages",
  beforeLoad: guardStep(2),
  component: lazyRouteComponent(
    () => import("../features/page-workspace/PageWorkspace"),
    "PageWorkspace",
  ),
});
const proofreadRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/$bookId/proofread",
  beforeLoad: guardStep(3),
  component: () => <StepPlaceholder step={3} title="OCR 与句子" nextMilestone="M3.3 将在这里接入 bbox、句子编辑、排序与确认门禁。" />,
});
const audioRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/$bookId/audio",
  beforeLoad: guardStep(4),
  component: () => <StepPlaceholder step={4} title="语音生成" nextMilestone="M3.4 将在这里接入试听、失败重试与音色设置。" />,
});
const exportRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/$bookId/export",
  beforeLoad: guardStep(5),
  component: () => <StepPlaceholder step={5} title="导出资源包" nextMilestone="M3.5 将在这里接入校验报告与资源包导出。" />,
});

const routeTree = rootRoute.addChildren([
  indexRoute,
  newBookRoute,
  pagesRoute,
  proofreadRoute,
  audioRoute,
  exportRoute,
]);

export const router = createRouter({ routeTree, context: { queryClient: undefined! } });

declare module "@tanstack/react-router" {
  interface Register { router: typeof router; }
}
