import { queryOptions } from "@tanstack/react-query";

import { getBookState, getCapabilities, getPageWorkspace } from "./client";

export const bookStateQuery = (bookId: string) =>
  queryOptions({
    queryKey: ["books", bookId, "state"],
    queryFn: () => getBookState(bookId),
    staleTime: 1000,
  });

export const capabilitiesQuery = queryOptions({
  queryKey: ["system", "capabilities"],
  queryFn: getCapabilities,
  staleTime: 30_000,
});

export const pageWorkspaceQuery = (bookId: string) =>
  queryOptions({
    queryKey: ["books", bookId, "pages", "workspace"],
    queryFn: () => getPageWorkspace(bookId),
    staleTime: 1000,
  });
