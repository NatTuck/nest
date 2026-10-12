/**
 * The app shell owns all scrolling: there is no page-level scrollbar.
 *
 * This is a *structural* test. jsdom has no layout engine, so it cannot
 * assert the real thing — that `documentElement.scrollHeight` equals
 * `clientHeight`, that the conversation pane is the only element which
 * actually scrolls on a chat page, and that the sidebar and the static
 * pages still scroll. That was verified in a real browser (Firefox,
 * headless) by rendering the real `Layout` + `ChatPage` DOM against the
 * real built stylesheet and measuring `scrollHeight`/`clientHeight` for
 * every `overflow: auto|scroll` element, at ten viewport sizes across
 * all seven `Layout` pages. See the "The app shell owns all scrolling"
 * comment in `assets/css/app.css`.
 *
 * What this file pins is the invariant those measurements rest on, so
 * the bug cannot come back silently. The failure it guards against is a
 * *second* viewport-height block inside `#root`: with the document
 * pinned only by `100vh` on one element, that grows the document by a
 * full screen, giving a page scrollbar with nothing but blank space
 * below the first screen. Measured before the fix, that case produced
 * `documentElement.scrollHeight - clientHeight === 800` (one full
 * viewport); with the pin below it is 0.
 *
 * Two things are asserted:
 *
 *   1. The height chain is `html` -> `body` -> `#root` -> shell, every
 *      link a percentage (`h-full`) and `#root` additionally
 *      `overflow-hidden`, so nothing rendered inside the app can grow
 *      the document.
 *   2. No part of the shell re-derives the viewport with `100vh`
 *      (`h-screen`). `vh` is the viewport *including* browser chrome, so
 *      a `100vh` shell is taller than the visible viewport wherever the
 *      chrome is not part of it — the other way this symptom appears.
 */
import { describe, it, expect, vi } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { renderWithRouter } from "./test/render_with_router";

// `App.jsx` pulls in the whole router, so the mock has to carry the real
// module's exports; spread the actual module and override only the calls
// that would open a socket.
vi.mock("./channels", async () => {
  const actual = await vi.importActual("./channels");
  return {
    ...actual,
    initChannels: vi.fn(),
    joinLobby: vi.fn(),
    leaveLobby: vi.fn(),
    joinAgent: vi.fn(),
    leaveAgent: vi.fn(),
  };
});

import { Layout } from "./App";
import { ChatMessages } from "./components/ChatMessages";
import { useStore } from "./store";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "..", "..");

function read(relativePath) {
  return fs.readFileSync(path.resolve(repoRoot, relativePath), "utf8");
}

// Every file that participates in the shell's height. `#root` is declared
// in the controller template, `html`/`body` in the root layout, and the
// rest are the React shells the app mounts inside `#root`.
const SHELL_SOURCES = [
  "lib/nest_web/components/layouts/root.html.heex",
  "lib/nest_web/controllers/page_html/home.html.heex",
  "assets/js/App.jsx",
  "assets/js/pages/LoginPage.jsx",
  "assets/js/pages/RegisterPage.jsx",
];

describe("the document height pin", () => {
  it("chains html, body and #root on percentages, and clips at #root", () => {
    const rootLayout = read("lib/nest_web/components/layouts/root.html.heex");
    const mountPoint = read(
      "lib/nest_web/controllers/page_html/home.html.heex",
    );

    expect(rootLayout).toMatch(/<html[^>]*class="[^"]*\bh-full\b/);
    expect(rootLayout).toMatch(/<body[^>]*class="[^"]*\bh-full\b/);
    expect(mountPoint).toMatch(/id="root"[^>]*class="[^"]*\bh-full\b/);
    expect(mountPoint).toMatch(/id="root"[^>]*class="[^"]*\boverflow-hidden\b/);
  });

  it("never pins a height with 100vh, which includes browser chrome", () => {
    for (const source of SHELL_SOURCES) {
      expect(
        read(source),
        `${source} must not re-derive the viewport with h-screen`,
      ).not.toMatch(/\bh-screen\b/);
    }
  });
});

describe("the shell", () => {
  it("fills #root and keeps <main> as the page's scroll region", async () => {
    const { container } = await renderWithRouter(<Layout />);

    const shell = container.firstElementChild;
    expect(shell.className).toContain("h-full");
    // The shell fills its container; it must not re-derive the viewport.
    expect(shell.className).not.toContain("h-screen");

    // `main` scrolls so the static pages (About, Spaces) still work. The
    // chat page additionally owns its own scroll region below.
    const main = container.querySelector("main");
    expect(main.className).toContain("flex-1");
    expect(main.className).toContain("overflow-auto");
  });
});

describe("the conversation pane", () => {
  it("is the chat page's scroll region, shrinking to make room for the chrome", async () => {
    // Rendered on its own: the point is the pane's own classes. With an
    // empty cache `MessagesList` renders nothing, so no fixture is needed.
    useStore.getState()._reset?.();

    const { container } = await renderWithRouter(
      <ChatMessages
        messages={[]}
        partial={null}
        archivedHistory={[]}
        lastCompactionIndex={-1}
        lastCompactionMarker={null}
        historyError={null}
        onLoadHistory={vi.fn()}
        onLoadOlder={vi.fn()}
        name="alpha"
        setScrollContainerEl={vi.fn()}
        setMessagesEndEl={vi.fn()}
      />,
    );

    const pane = container.firstElementChild;
    // `flex-1` lets the pane absorb the slack; `overflow-y-auto` is what
    // makes it the scroll region *and* what gives it `min-height: 0`, so
    // it shrinks instead of pushing the chat chrome past `main` (which
    // would make `main` scroll and move the whole page instead).
    expect(pane.className).toContain("flex-1");
    expect(pane.className).toContain("overflow-y-auto");
  });
});
