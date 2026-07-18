import { queryOptions } from "@tanstack/react-query";

import { getAudioWorkspace, getBookState, getCapabilities, getExportWorkspace, getPageWorkspace, getProofreadWorkspace } from "./client";

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

export const proofreadWorkspaceQuery = (bookId: string) =>
  queryOptions({
    queryKey: ["books", bookId, "proofread", "workspace"],
    queryFn: () => getProofreadWorkspace(bookId),
    staleTime: 1000,
  });

export const audioWorkspaceQuery = (bookId: string) =>
  queryOptions({
    queryKey: ["books", bookId, "audio", "workspace"],
    queryFn: () => getAudioWorkspace(bookId),
    staleTime: 1000,
  });

export const exportWorkspaceQuery = (bookId: string) =>
  queryOptions({
    queryKey: ["books", bookId, "export", "workspace"],
    queryFn: () => getExportWorkspace(bookId),
    staleTime: 1000,
  });
