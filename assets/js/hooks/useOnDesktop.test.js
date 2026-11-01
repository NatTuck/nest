/**
 * `useOnDesktop` tests: the one place the UI reads the viewport.
 *
 * The hook exists to retire phone-only *state* when a window is widened past
 * `lg` — the navigation drawer and the chat page's pane tab both have `lg:hidden`
 * controls, so leaving them selected on a desktop strands them. It must fire on
 * the crossing into the desktop layout and at no other time, and it must let go
 * of its listener when the component unmounts.
 *
 * jsdom has no `matchMedia` at all, so the query and its `change` event are
 * stubbed narrowly (`test/match_media.js`): a stub of the event, not of a width,
 * because nothing in the UI may branch on a viewport size.
 *
 * The last suite here is a source scan rather than a behaviour test: the
 * breakpoint itself is written down more than once, and a copy that drifts is
 * not a style bug — it strands phone state on a desktop (see the hook's doc).
 */

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { describe, it, expect, vi, afterEach } from "vitest";
import { act, renderHook } from "@testing-library/react";

import { stubDesktopQuery } from "../test/match_media";
import { DESKTOP_QUERY, useOnDesktop } from "./useOnDesktop";

// The hook's own source, as text: Vite's `?raw` keeps this independent of the
// directory the suite is started from. The stylesheet is read with `node:fs`
// instead — `?raw` on a `.css` file goes through the Tailwind plugin and comes
// back empty — so it is resolved against the suite's working directory, which is
// `assets` for every entry point there is (`cmd --cd assets` in `mix.exs`, and
// the documented `cd assets && …`). A different directory fails loudly, naming
// the path, rather than passing on an empty string.
import hookSource from "./useOnDesktop.js?raw";

const appCss = readFileSync(resolve(process.cwd(), "css/app.css"), "utf8");

let media;

afterEach(() => {
  media?.restore();
  media = undefined;
});

describe("useOnDesktop", () => {
  it("calls back when the window widens past the breakpoint, and never on mount", () => {
    media = stubDesktopQuery();
    const onDesktop = vi.fn();

    renderHook(() => useOnDesktop(onDesktop));

    // Mounting is not a crossing: the window was already whatever it was, and
    // the state was built for that layout.
    expect(onDesktop).not.toHaveBeenCalled();

    // Narrowing is the phone layout, where a drawer or a pane tab is valid.
    act(() => media.narrow());
    expect(onDesktop).not.toHaveBeenCalled();

    act(() => media.cross());
    expect(onDesktop).toHaveBeenCalledTimes(1);
  });

  it("stops listening when the component unmounts", () => {
    media = stubDesktopQuery();
    const onDesktop = vi.fn();
    const { unmount } = renderHook(() => useOnDesktop(onDesktop));

    unmount();
    act(() => media.cross());

    expect(onDesktop).not.toHaveBeenCalled();
  });
});

describe("the desktop breakpoint", () => {
  // `64rem` is written down in three places, and they have to agree:
  //
  //   1. Tailwind's `lg`, whose default is 64rem — the layout every `lg:` and
  //      `max-lg:` class is measured against;
  //   2. `assets/css/app.css`'s `.phone-drawer` media query, which decides
  //      whether the sidebar is a static column or an off-canvas panel;
  //   3. `DESKTOP_QUERY`, which decides when phone-only state is retired.
  //
  // If (2) and (3) drift apart, a window at the in-between width gets a static
  // sidebar with the drawer's state still marked open — `main` `inert`, and no
  // control left that can close it. (1) cannot be read from here (it is
  // Tailwind's own default), so it is named in this comment: if `lg` ever moves,
  // these two numbers move with it. This is the same source-scan pin the Elixir
  // side uses for the provider placeholders (`Nest.DotConfigJsDefaultsTest`).
  it("matches the media query the stylesheet hides the drawer with", () => {
    const cssQuery = appCss.match(
      /@media \(([^)]+)\)\s*\{\s*\.phone-drawer\b/,
    )?.[1];
    const declared = hookSource.match(/DESKTOP_QUERY = "([^"]+)"/)?.[1];

    expect(cssQuery).toBe("min-width: 64rem");
    // The constant is a literal, and it is the one the hook subscribes to.
    expect(declared).toBe("(min-width: 64rem)");
    expect(declared).toBe(DESKTOP_QUERY);
    expect(`(${cssQuery})`).toBe(DESKTOP_QUERY);
  });
});
