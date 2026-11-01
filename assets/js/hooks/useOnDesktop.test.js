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
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import { act, renderHook } from "@testing-library/react";

import { stubDesktopQuery } from "../test/match_media";
import { useOnDesktop } from "./useOnDesktop";

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
