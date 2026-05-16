import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";

export function initApp(element) {
  const root = createRoot(element);
  root.render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}
