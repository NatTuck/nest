// Phoenix HTML helpers
import "phoenix_html";

// Import CSS - Vite handles CSS bundling
import "../css/app.css";

// Initialize React app
import { initApp } from "./root";

// Mount React app when DOM is ready
document.addEventListener("DOMContentLoaded", () => {
  const rootElement = document.getElementById("root");
  if (rootElement) {
    initApp(rootElement);
  }
});

// Development features for Phoenix Live Reload
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client
      reloader.enableServerLogs();

      // Open editor on click with modifier keys
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
