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
 */

import { useCopyToClipboard } from "../utils/clipboard.js";

/**
 * @param {object} props
 * @param {string} props.text
 *   The string to write to the clipboard when the button is clicked.
 * @param {string} [props.label="Copy"]
 *   The `aria-label` and `title` for the button (used for the
 *   tooltip and by screen readers / tests).
 * @param {number} [props.feedbackMs=2000]
 *   How long the check icon is shown after a successful copy.
 */
export function CopyButton({ text, label = "Copy", feedbackMs = 2000 }) {
  const [copied, copy] = useCopyToClipboard(feedbackMs);

  const handleClick = () => {
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
