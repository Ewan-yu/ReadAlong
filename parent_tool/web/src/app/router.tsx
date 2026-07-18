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
  component: lazyRouteComponent(
    () => import("../features/proofread-workspace/ProofreadWorkspace"),
    "ProofreadWorkspace",
  ),
});
const audioRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/$bookId/audio",
  beforeLoad: guardStep(4),
  component: lazyRouteComponent(
    () => import("../features/audio-generation/AudioGenerationPage"),
    "AudioGenerationPage",
  ),
});
const exportRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/books/$bookId/export",
  beforeLoad: guardStep(5),
  component: lazyRouteComponent(
    () => import("../features/export-book/ExportBookPage"),
    "ExportBookPage",
  ),
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
