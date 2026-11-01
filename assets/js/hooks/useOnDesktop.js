/**
 * Run `onDesktop` when the window crosses into the desktop layout (`lg`, 64rem).
 *
 * This is the UI's **only** viewport read, and it is deliberately not a layout
 * branch: every style is still decided by Tailwind's breakpoints alone. What it
 * retires is *state* that a breakpoint cannot retire, because the control that
 * owns it is `lg:hidden`. Two pieces of state are phone-only:
 *
 *   * the navigation drawer — at `lg`+ the sidebar is the layout's static first
 *     column, so the hamburger and the backdrop are both gone. A window widened
 *     while the drawer is open would leave `main` marked `inert` with nothing on
 *     screen that can close it, which is a page nobody can click;
 *   * the chat page's pane tab — at `lg`+ the pane is the sibling column and the
 *     tab is not offered, so the bar would show no selected tab at all.
 *
 * Both callbacks put that state back where a desktop starts (`Layout` closes the
 * drawer, `ChatPage` selects the conversation), and they run inside the media
 * query's own change event, so the render that follows already has the right
 * state — there is no frame in between that shows the stranded version.
 *
 * **Do not** grow this into an `isDesktop` value and branch JSX on it. A view
 * that differs by width belongs in a `lg:` class, where it cannot disagree with
 * the CSS; this hook answers one question, "the phone layout just went away, is
 * anything stranded?", and only when the answer changes.
 *
 * `onDesktop` must be reference-stable (`useCallback`), or the listener is torn
 * down and rebuilt on every render. Without `matchMedia` — jsdom, and any
 * browser old enough to lack it — there is no callback and no crash: a stranded
 * drawer is then only reachable by resizing, which beats a UI that cannot
 * decide whether it is a phone.
 */

import { useEffect } from "react";

/** Tailwind's `lg`, in the same units the stylesheet's own query uses. */
export const DESKTOP_QUERY = "(min-width: 64rem)";

export function useOnDesktop(onDesktop) {
  useEffect(() => {
    const query = window.matchMedia?.(DESKTOP_QUERY);
    if (typeof query?.addEventListener !== "function") return;

    const handleChange = (event) => {
      // Only the crossing *into* the desktop layout retires anything. Narrowing
      // back to a phone leaves the drawer closed and the conversation selected,
      // which are both valid phone states.
      if (event.matches) onDesktop();
    };

    query.addEventListener("change", handleChange);
    return () => query.removeEventListener("change", handleChange);
  }, [onDesktop]);
}

export default useOnDesktop;
