/**
 * The floating "Jump to latest" button that sits above a composer.
 *
 * Positioned `absolute bottom-full` inside a `relative` wrapper, so it stays
 * visible regardless of which ancestor scrolls — it is deliberately in the
 * column's coordinate space rather than inside the scroll container.
 *
 * Extracted from `ChatComposer` when the space feed needed the same affordance:
 * the feed renders `ChatInput` directly rather than `ChatComposer`, so without
 * this the markup and its `aria-label` would have had two homes.
 *
 * Shown only when there is unseen content *and* the reader is away from the
 * bottom. Both conditions matter: content arrives while they are at the bottom
 * and it has already been followed, so there is nothing to jump to.
 */
export function JumpToBottomButton({
  hasNewContent,
  isAtBottom,
  jumpToBottom,
}) {
  if (!hasNewContent || isAtBottom) return null;

  return (
    <button
      type="button"
      onClick={jumpToBottom}
      aria-label="Jump to latest messages"
      className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 z-10 px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded-full shadow-lg hover:bg-indigo-700 transition-all duration-200 flex items-center gap-1.5"
    >
      <svg
        className="w-4 h-4"
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
        aria-hidden="true"
      >
        <path
          strokeLinecap="round"
          strokeLinejoin="round"
          strokeWidth={2}
          d="M19 14l-7 7m0 0l-7-7m7 7V3"
        />
      </svg>
      Jump to latest
    </button>
  );
}
