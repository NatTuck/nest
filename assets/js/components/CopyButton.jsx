/**
 * Reusable copy button for the chat UI.
 *
 * Renders a small icon button. By default it shows a clipboard icon;
 * after a successful copy it swaps to a check icon for `feedbackMs`
 * (default 2000ms), then reverts. Click feedback is driven by
 * `useCopyToClipboard`, so each `<CopyButton>` instance has its own
 * timer state — multiple buttons in the same view (e.g. one per
 * message) are independent.
 *
 * The button is always visible (no `opacity-0 group-hover:...` dance)
 * because the chat is the primary read surface; users should not have
 * to discover the action by hovering. The text color and hover
 * treatment are deliberately muted (gray-400 → gray-700) so the
 * button does not compete visually with the message text.
 *
 * The text to copy is supplied as a `getText` callback, not a string
 * prop. The callback is invoked only when the user clicks — the
 * button never materializes the text during render. This is the
 * performance-critical contract: a 100k-token conversation has ~200
 * messages, each with a copy button; eager text materialization
 * would allocate a markdown blob per message per render, multiplying
 * garbage by the streaming delta rate (10–50 deltas/sec). Lazy
 * resolution means the work happens only when the user actually
 * clicks, which is rare for most buttons.
 */

import { useCopyToClipboard } from "../utils/clipboard.js";

/**
 * @param {object} props
 * @param {() => string} props.getText
 *   A callback that returns the string to write to the clipboard.
 *   Called only on click. Must return a string; non-string returns
 *   are silently ignored (matching `copyToClipboard`'s behavior at
 *   `clipboard.js:30`). If the callback throws, the error is logged
 *   with the project's `[NEST REGRESSION]` prefix and the click is
 *   a no-op.
 * @param {string} [props.label="Copy"]
 *   The `aria-label` and `title` for the button (used for the
 *   tooltip and by screen readers / tests).
 * @param {number} [props.feedbackMs=2000]
 *   How long the check icon is shown after a successful copy.
 */
export function CopyButton({ getText, label = "Copy", feedbackMs = 2000 }) {
  const [copied, copy] = useCopyToClipboard(feedbackMs);

  const handleClick = () => {
    let text;
    try {
      text = getText();
    } catch (err) {
      // Match the project's `[NEST REGRESSION]` prefix used by
      // `copyToClipboard` itself when the underlying API throws.
      // Don't re-throw — the button is a leaf, a failure here
      // should not break the parent component.
      console.error("[NEST REGRESSION] CopyButton getText threw", err);
      return;
    }
    // `copyToClipboard` itself silently ignores non-string inputs
    // (clipboard.js:30). Mirror that here so a caller returning
    // `undefined` or `null` doesn't surface as a confusing "Copied"
    // feedback with no actual write.
    if (typeof text !== "string") return;
    copy(text);
  };

  const actionLabel = copied ? "Copied" : label;

  return (
    <button
      type="button"
      onClick={handleClick}
      aria-label={actionLabel}
      title={actionLabel}
      className="inline-flex items-center justify-center w-6 h-6 rounded text-gray-400 hover:text-gray-700 hover:bg-gray-200 transition-colors"
    >
      {copied ? <CheckIcon /> : <ClipboardIcon />}
    </button>
  );
}

function ClipboardIcon() {
  return (
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
        d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
      />
    </svg>
  );
}

function CheckIcon() {
  return (
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
        d="M5 13l4 4L19 7"
      />
    </svg>
  );
}
