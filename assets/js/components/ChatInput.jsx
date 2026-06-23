import { useEffect, useLayoutEffect, useRef, useState } from "react";
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
 * - Ctrl+Up / Ctrl+Down (and Cmd+Up / Cmd+Down on macOS) walks the
 *   textarea through the user's previously sent messages for the
 *   current agent. The first Up loads the most recent message; further
 *   Ups walk to older messages. Down walks forward; pressing Down at
 *   the newest entry restores the unsent "draft" text that was in the
 *   textarea when navigation began. Pressing the keys with no history
 *   is a no-op.
 * - When the user manually edits the loaded entry (the new value
 *   diverges from the historical entry on screen), the cursor resets
 *   to "draft" mode so subsequent Up/Down starts from the new text.
 * - Loading a historical entry also restores its `mode` via
 *   `onModeChange` if a mode is recorded for it.
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
 *
 * Props:
 * - `history`: array of `{ content: string, mode: string | null }`,
 *   ordered most-recent-first, with consecutive duplicates removed.
 *   The parent is responsible for building this list from the agent's
 *   current and archived messages. When non-empty and the input is
 *   interactive, a small muted hint is rendered below the form to
 *   advertise the keybinding.
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
  history = [],
}) {
  const textareaRef = useRef(null);

  // History-navigation cursor. -1 means "draft" (the textarea shows
  // the user's current typing, or the saved draft if they've already
  // navigated once). 0..history.length-1 indexes into the history
  // array (most-recent first). Reset whenever the parent passes in a
  // different history array (e.g. agent switch).
  const [cursor, setCursor] = useState(-1);
  const [draft, setDraft] = useState("");

  // biome-ignore lint/correctness/useExhaustiveDependencies: only `value` should retrigger resize
  useLayoutEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${Math.min(el.scrollHeight, MAX_HEIGHT_PX)}px`;
    el.style.overflowY = el.scrollHeight > MAX_HEIGHT_PX ? "auto" : "hidden";
  }, [value]);

  // Reset history navigation whenever the parent hands us a new
  // history array (agent change, or the underlying messages list
  // reorders / gets replaced on reconnect). Without this, switching
  // agents could leave the cursor pointing at a stale entry from
  // the previous agent.
  useEffect(() => {
    // Reference `history` so biome accepts the dependency: the effect
    // should re-run only when the parent hands us a new history array
    // (e.g. agent switch). Reading it here is the explicit signal of
    // intent — otherwise biome flags `[history]` as unused.
    void history;
    setCursor(-1);
    setDraft("");
  }, [history]);

  // Wrap the parent's onChange so we can detect when the user
  // diverges from a loaded historical entry. When that happens we
  // drop back into "draft" mode and snapshot the new text as the
  // draft, so a subsequent Down will return here instead of to the
  // historical entry we were just on.
  const handleChange = (newValue) => {
    if (cursor !== -1 && newValue !== history[cursor]?.content) {
      setCursor(-1);
      setDraft(newValue);
    } else if (cursor === -1) {
      setDraft(newValue);
    }
    onChange(newValue);
  };

  const handleKeyDown = (e) => {
    if (e.nativeEvent.isComposing) return;
    if (disabled || isBusy) return;

    // Enter handling — unchanged.
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      if (!value.trim()) return;
      onSend();
      return;
    }

    // History navigation: Ctrl/Cmd + ArrowUp / ArrowDown. Skipped
    // when the modifier is absent so plain Up/Down still moves the
    // text caret as the user expects.
    if (!(e.ctrlKey || e.metaKey)) return;
    if (e.key !== "ArrowUp" && e.key !== "ArrowDown") return;

    if (history.length === 0) {
      // Still consume the event so the browser doesn't try to do
      // anything else with it (e.g. scroll the page).
      e.preventDefault();
      return;
    }

    e.preventDefault();

    if (e.key === "ArrowUp") {
      const nextCursor =
        cursor === -1 ? 0 : Math.min(cursor + 1, history.length - 1);
      if (nextCursor === cursor) return; // already at oldest entry
      if (cursor === -1) setDraft(value); // snapshot current typing
      const entry = history[nextCursor];
      onChange(entry.content);
      if (entry.mode && onModeChange) onModeChange(entry.mode);
      setCursor(nextCursor);
      return;
    }

    // ArrowDown
    if (cursor === -1) return; // already at draft
    if (cursor === 0) {
      onChange(draft);
      setCursor(-1);
      return;
    }
    const nextCursor = cursor - 1;
    const entry = history[nextCursor];
    onChange(entry.content);
    if (entry.mode && onModeChange) onModeChange(entry.mode);
    setCursor(nextCursor);
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
          onChange={(e) => handleChange(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder={placeholder}
          disabled={disabled || isBusy}
          rows={2}
          aria-label="Message"
          aria-keyshortcuts="Control+ArrowUp Control+ArrowDown Meta+ArrowUp Meta+ArrowDown Control+Enter Meta+Enter"
          title="Enter to newline • Ctrl/Cmd+Enter to send • Ctrl/Cmd+Up/Down to walk previous prompts"
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
      {history.length > 0 && !disabled && !isBusy && (
        <p className="mt-1 px-1 text-xs text-gray-400" aria-hidden="true">
          Tip: Ctrl+↑ / Ctrl+↓ to walk previous prompts
        </p>
      )}
    </form>
  );
}
