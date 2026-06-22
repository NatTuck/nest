import { useLayoutEffect, useRef } from "react";
import { ModeSelector } from "./ModeSelector";

const MAX_HEIGHT_PX = 240;

/**
 * Auto-resizing chat text input with optional mode selector.
 *
 * Behavior:
 * - Renders a multi-line textarea (default 2 rows) that grows with content
 *   up to MAX_HEIGHT_PX, then scrolls internally.
 * - Enter inserts a newline.
 * - Ctrl+Enter or Meta+Enter (Cmd on macOS) sends.
 * - Skips the keydown handler while an IME composition is in progress.
 * - Submitting via the Send button or Ctrl/Cmd+Enter calls onSend.
 * - When `modes` has more than one entry, renders a ModeSelector next
 *   to the send button. The current selection is `mode`; the user can
 *   change it via `onModeChange`.
 * - When `isBusy` is true (agent is streaming or executing tools),
 *   the Send button is replaced with a Stop button that calls
 *   `onStop`. If `stopping` is also true, the button shows
 *   "Stopping..." (with a spinner) until the next `chat:status`
 *   push transitions the agent back to idle and the page
 *   re-renders with `isBusy=false`.
 */
export function ChatInput({
  value,
  onChange,
  onSend,
  onStop,
  isBusy,
  stopping,
  disabled,
  placeholder,
  modes,
  mode,
  onModeChange,
}) {
  const textareaRef = useRef(null);

  // biome-ignore lint/correctness/useExhaustiveDependencies: only `value` should retrigger resize
  useLayoutEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, MAX_HEIGHT_PX)}px`;
    el.style.overflowY = el.scrollHeight > MAX_HEIGHT_PX ? "auto" : "hidden";
  }, [value]);

  const handleKeyDown = (e) => {
    if (e.nativeEvent.isComposing) return;
    if (e.key !== "Enter") return;
    if (!(e.ctrlKey || e.metaKey)) return;

    e.preventDefault();
    if (disabled || isBusy) return;
    if (!value.trim()) return;
    onSend();
  };

  // Three-way button: when the agent is busy, show a Stop button
  // (or a "Stopping..." disabled placeholder once the click has
  // been issued). When the agent is idle, show the normal Send
  // button.
  const renderActionButton = () => {
    if (isBusy && stopping) {
      return (
        <button
          type="button"
          disabled
          aria-label="Stopping"
          className="px-6 py-3 rounded-lg font-semibold text-white bg-red-400 cursor-not-allowed leading-tight flex items-center gap-2"
        >
          <svg
            className="animate-spin h-4 w-4"
            viewBox="0 0 24 24"
            aria-hidden="true"
          >
            <circle
              className="opacity-25"
              cx="12"
              cy="12"
              r="10"
              stroke="currentColor"
              strokeWidth="4"
              fill="none"
            />
            <path
              className="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            />
          </svg>
          Stopping...
        </button>
      );
    }

    if (isBusy) {
      return (
        <button
          type="button"
          onClick={onStop}
          aria-label="Stop"
          className="px-6 py-3 rounded-lg font-semibold text-white bg-red-600 hover:bg-red-700 active:bg-red-800 transition-all duration-200 leading-tight"
        >
          Stop
          <span className="block text-xs font-normal opacity-75">
            Halt response
          </span>
        </button>
      );
    }

    return (
      <button
        type="submit"
        disabled={disabled || !value.trim()}
        className={`px-6 py-3 rounded-lg font-semibold text-white transition-all duration-200 leading-tight ${
          disabled || !value.trim()
            ? "bg-gray-400 cursor-not-allowed"
            : "bg-blue-600 hover:bg-blue-700 active:bg-blue-800"
        }`}
      >
        Send
        <span className="block text-xs font-normal opacity-75">Ctrl+Enter</span>
      </button>
    );
  };

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (disabled || isBusy) return;
        if (!value.trim()) return;
        onSend();
      }}
      className="border-t border-gray-200 pt-4"
    >
      <div className="flex gap-2">
        <textarea
          ref={textareaRef}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={placeholder}
          disabled={disabled || isBusy}
          rows={2}
          aria-label="Message"
          className="flex-1 px-4 py-3 border border-gray-300 rounded-lg resize-none overflow-y-auto leading-snug focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none disabled:bg-gray-100 disabled:cursor-not-allowed"
          style={{ maxHeight: `${MAX_HEIGHT_PX}px` }}
        />
        {modes && modes.length > 1 && onModeChange && (
          <ModeSelector
            modes={modes}
            value={mode}
            onChange={onModeChange}
            disabled={disabled || isBusy}
          />
        )}
        {renderActionButton()}
      </div>
    </form>
  );
}
