import { RouterProvider } from "@tanstack/react-router";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { AppProviders, queryClient } from "./app/providers";
import { router } from "./app/router";
import "./styles/global.css";

const root = document.getElementById("root");
if (!root) throw new Error("Missing application root");

createRoot(root).render(
  <StrictMode>
    <AppProviders>
      <RouterProvider router={router} context={{ queryClient }} />
    </AppProviders>
  </StrictMode>,
);
