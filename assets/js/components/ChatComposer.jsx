/**
 * The chat input area with the floating "Jump to latest" button above it.
 * Positioned in the column's coordinate space (not inside the scroll
 * container) so it stays visible regardless of which ancestor scrolls.
 * Extracted from `ChatPage`.
 */

import { ChatInput } from "./ChatInput";

export function ChatComposer({
  inputValue,
  onChange,
  onSend,
  onStop,
  isBusy,
  stopping,
  disabled,
  frozen,
  placeholder,
  modes,
  mode,
  onModeChange,
  history,
  hasNewContent,
  isAtBottom,
  jumpToBottom,
}) {
  return (
    <div className="relative">
      {hasNewContent && !isAtBottom && (
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
      )}

      <ChatInput
        value={inputValue}
        onChange={onChange}
        onSend={onSend}
        onStop={onStop}
        isBusy={isBusy}
        stopping={stopping}
        disabled={disabled}
        frozen={frozen}
        placeholder={placeholder}
        modes={modes}
        mode={mode}
        onModeChange={onModeChange}
        history={history}
      />
    </div>
  );
}
