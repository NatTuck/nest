import { useEffect, useLayoutEffect, useState } from "react";

const BOTTOM_THRESHOLD_PX = 300;

/**
 * Drives the "scroll to bottom on new content, show a jump button when
 * scrolled up" behavior for a scrollable container.
 *
 * - Tracks whether the user is within BOTTOM_THRESHOLD_PX of the bottom
 *   via a passive scroll listener.
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

  // Track scroll position so we can decide whether to auto-scroll on new content.
  // We do not run an initial check: the hook assumes "at bottom" on first mount
  // (the useLayoutEffect below scrolls there), and only updates from real user
  // scroll events after that.
  // biome-ignore lint/correctness/useExhaustiveDependencies: id triggers re-attach on conversation change
  useEffect(() => {
    if (!scrollContainerEl) return;

    const checkAtBottom = () => {
      const atBottom =
        scrollContainerEl.scrollHeight -
          scrollContainerEl.scrollTop -
          scrollContainerEl.clientHeight <
        BOTTOM_THRESHOLD_PX;
      setIsAtBottom(atBottom);
      if (atBottom) setHasNewContent(false);
    };

    scrollContainerEl.addEventListener("scroll", checkAtBottom, {
      passive: true,
    });
    return () => scrollContainerEl.removeEventListener("scroll", checkAtBottom);
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
