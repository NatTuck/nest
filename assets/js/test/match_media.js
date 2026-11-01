/**
 * A controllable stand-in for the desktop media query, for tests.
 *
 * jsdom does not implement `matchMedia` at all (the property is absent, not a
 * throwing stub), and `useOnDesktop` is the one place the UI reads the viewport.
 * So this stub is deliberately narrow: it answers that one query, and its
 * `cross`/`narrow` helpers fire the `change` handlers the hook registered —
 * which is what a browser does when a window is resized across the breakpoint.
 *
 * It is a stub of the *event*, not of a width: nothing in the UI may branch on a
 * viewport size, so there is no width to fake. Call `restore()` when the test
 * ends; the property did not exist before.
 *
 *     let media;
 *     afterEach(() => media?.restore());
 *
 *     it("...", () => {
 *       media = stubDesktopQuery();
 *       render(<Thing />);
 *       act(() => media.cross());
 *     });
 */

import { DESKTOP_QUERY } from "../hooks/useOnDesktop";

export function stubDesktopQuery() {
  const listeners = new Set();
  const query = {
    matches: false,
    media: DESKTOP_QUERY,
    addEventListener: (type, handler) => {
      if (type === "change") listeners.add(handler);
    },
    removeEventListener: (type, handler) => {
      if (type === "change") listeners.delete(handler);
    },
  };
  const previous = window.matchMedia;

  window.matchMedia = (media) =>
    media === DESKTOP_QUERY
      ? query
      : {
          matches: false,
          media,
          addEventListener() {},
          removeEventListener() {},
        };

  const fire = (matches) => {
    query.matches = matches;
    // A copy: a handler is allowed to unsubscribe itself.
    for (const handler of [...listeners]) {
      handler({ matches, media: DESKTOP_QUERY });
    }
  };

  return {
    /** The window was widened past `lg`. */
    cross: () => fire(true),
    /** The window was narrowed back below `lg`. */
    narrow: () => fire(false),
    restore: () => {
      window.matchMedia = previous;
    },
  };
}

export default stubDesktopQuery;
