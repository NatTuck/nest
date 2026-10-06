import { useEffect, useLayoutEffect, useState } from "react";

const AT_BOTTOM_EPSILON_PX = 2;

/**
 * Drives the "scroll to bottom on new content, show a jump button when
 * scrolled up" behavior for a scrollable container.
 *
 * - Tracks whether the container is pinned to the bottom. A `scroll`
 *   event *re-pins* whenever the container lands within
 *   AT_BOTTOM_EPSILON_PX of the bottom (`isAtBottom` becomes true and
 *   `hasNewContent` clears), and *un-pins* only when it moved upward
 *   (`scrollTop` decreased) while still away from the bottom. The
 *   direction check is what covers scrolls the browser performs without a
 *   wheel/touch/key event we can observe -- dragging the scrollbar, or
 *   Space / Shift+Space. Content growth does not un-pin: it changes
 *   `scrollHeight` only, never `scrollTop`, and our own programmatic
 *   scrolls only ever increase `scrollTop`.
 * - Un-pinning also happens immediately on a real user gesture, however
 *   far it moved: a `wheel` event with `deltaY < 0` or a `touchmove` on
 *   the container, and a `keydown` for PageUp / ArrowUp / Home on
 *   `window` (focus is usually in the composer textarea, so a
 *   container-only key listener would miss PgUp).
 * - On new content (controlled by the caller via the `trigger` value),
 *   auto-scrolls to the end if the user is at the bottom, or surfaces
 *   `hasNewContent = true` if the user is scrolled up.
 * - Resets to "at bottom, no pending content" whenever `id` changes
 *   (e.g. navigating to a different conversation), so the new view
 *   starts at the latest message and the button does not flash.
 *
 * Both element arguments are real DOM nodes (or null) rather than ref
 * objects. Using state-backed callback refs in the caller means these
 * values transition from `null` to a real element when the JSX mounts,
 * and this hook's effects re-run in response -- which is essential when
 * the scroll container is mounted after the component's first render
 * (e.g. when the page initially renders a loading state and only
 * later renders the messages view).
 *
 * @param {HTMLElement|null} scrollContainerEl
 *   The scrollable container element. May be null on first render.
 * @param {HTMLElement|null} messagesEndEl
 *   The anchor element at the end of the message list. May be null on
 *   first render.
 * @param {string|null|undefined} id
 *   Conversation id; changing it resets the hook.
 * @param {unknown} trigger
 *   Value that, when it changes, should cause a re-evaluation of the
 *   scroll position. Typically the message list reference or the latest
 *   streaming token.
 * @returns {{ isAtBottom: boolean, hasNewContent: boolean, jumpToBottom: () => void }}
 */
export function useScrollToBottom(
  scrollContainerEl,
  messagesEndEl,
  id,
  trigger,
) {
  const [isAtBottom, setIsAtBottom] = useState(true);
  const [hasNewContent, setHasNewContent] = useState(false);

  // Attach the listeners that decide "is the user at the bottom?".
  // We do not run an initial check: the hook assumes "at bottom" on
  // first mount (the useLayoutEffect below scrolls there), and only
  // updates from real events after that.
  // biome-ignore lint/correctness/useExhaustiveDependencies: id triggers re-attach on conversation change
  useEffect(() => {
    if (!scrollContainerEl) return;

    // Reaching the bottom (or the smooth jumpToBottom animation finishing)
    // means the user wants to follow along again. A scroll that moved
    // *upward* while still away from the bottom is a user scroll-up even
    // when no wheel/touch/key event reached us: that is how a scrollbar
    // drag or Space / Shift+Space shows up. Content growth cannot trigger
    // this branch -- it changes scrollHeight, not scrollTop, and scrollTop
    // only decreases when the user (or the browser on the user's behalf)
    // actually scrolled up.
    let lastScrollTop = scrollContainerEl.scrollTop;
    const handleScroll = () => {
      const { scrollHeight, scrollTop, clientHeight } = scrollContainerEl;
      const distanceFromBottom = scrollHeight - scrollTop - clientHeight;

      if (distanceFromBottom <= AT_BOTTOM_EPSILON_PX) {
        setIsAtBottom(true);
        setHasNewContent(false);
      } else if (scrollTop < lastScrollTop) {
        setIsAtBottom(false);
      }

      lastScrollTop = scrollTop;
    };

    // Real user input that scrolls up. A wheel-up or touch drag is an
    // unambiguous intent to leave the bottom, regardless of how far it
    // moved (a few pixels is enough).
    const handleWheel = (event) => {
      if (event.deltaY < 0) setIsAtBottom(false);
    };
    const handleTouchMove = () => setIsAtBottom(false);

    // Keyboard scroll-ups. The composer textarea usually holds focus, so
    // listen on `window` rather than the container.
    //
    // PageUp and ArrowUp/Home are treated differently. PageUp is never
    // handled by the textarea itself: the browser routes it to the scroll
    // container even while the composer has focus, and issue #6 requires
    // it to stop auto-scroll. ArrowUp/Home are ambiguous -- in a text
    // field they move the caret, and Ctrl/Cmd+ArrowUp is the composer's
    // own history-walk shortcut -- so they only count as scroll-up intent
    // when focus is outside any editable field and no modifier is held.
    const isEditableTarget = (target) =>
      target instanceof Element &&
      target.closest("input, textarea, select, [contenteditable]") !== null;

    const handleKeyDown = (event) => {
      if (event.key === "PageUp") {
        setIsAtBottom(false);
        return;
      }

      if (event.key !== "ArrowUp" && event.key !== "Home") return;
      if (event.ctrlKey || event.metaKey || event.altKey) return;
      if (isEditableTarget(event.target)) return;

      setIsAtBottom(false);
    };

    scrollContainerEl.addEventListener("scroll", handleScroll, {
      passive: true,
    });
    scrollContainerEl.addEventListener("wheel", handleWheel, {
      passive: true,
    });
    scrollContainerEl.addEventListener("touchmove", handleTouchMove, {
      passive: true,
    });
    window.addEventListener("keydown", handleKeyDown);

    return () => {
      scrollContainerEl.removeEventListener("scroll", handleScroll);
      scrollContainerEl.removeEventListener("wheel", handleWheel);
      scrollContainerEl.removeEventListener("touchmove", handleTouchMove);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [id, scrollContainerEl]);

  // Auto-scroll on new content, but only if the user is already at the bottom.
  // If the user has scrolled up, surface hasNewContent for a "Jump to latest" button.
  // biome-ignore lint/correctness/useExhaustiveDependencies: trigger is the caller-supplied re-run signal
  useEffect(() => {
    if (!messagesEndEl) return;
    if (isAtBottom) {
      messagesEndEl.scrollIntoView({ behavior: "auto", block: "end" });
    } else {
      setHasNewContent(true);
    }
  }, [trigger, isAtBottom, messagesEndEl]);

  // On mount and id change, jump to the bottom of the new conversation
  // (useLayoutEffect to avoid a flash of un-scrolled content).
  // biome-ignore lint/correctness/useExhaustiveDependencies: id triggers re-init on conversation change
  useLayoutEffect(() => {
    if (!messagesEndEl) return;
    setHasNewContent(false);
    setIsAtBottom(true);
    messagesEndEl.scrollIntoView({ behavior: "auto", block: "end" });
  }, [id, messagesEndEl]);

  const jumpToBottom = () => {
    if (!messagesEndEl) return;
    messagesEndEl.scrollIntoView({ behavior: "smooth", block: "end" });
    setHasNewContent(false);
  };

  return { isAtBottom, hasNewContent, jumpToBottom };
}
