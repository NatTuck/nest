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
 */
export function ChatInput({
  value,
  onChange,
  onSend,
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
    if (disabled) return;
    if (!value.trim()) return;
    onSend();
  };

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (disabled) return;
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
          disabled={disabled}
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
            disabled={disabled}
          />
        )}
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
          <span className="block text-xs font-normal opacity-75">
            Ctrl+Enter
          </span>
        </button>
      </div>
    </form>
  );
}
