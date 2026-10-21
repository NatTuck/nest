/**
 * The chat input area with the floating "Jump to latest" button above it.
 * Positioned in the column's coordinate space (not inside the scroll
 * container) so it stays visible regardless of which ancestor scrolls, and
 * `shrink-0` so the column's flex line can never squeeze it: the chrome region
 * above is the part that shrinks when the header and banners alone are taller
 * than the viewport (issue #86).
 * Extracted from `ChatPage`.
 */

import { ChatInput } from "./ChatInput";
import { JumpToBottomButton } from "./JumpToBottomButton";

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
  commands,
  hasNewContent,
  isAtBottom,
  jumpToBottom,
}) {
  return (
    <div className="relative shrink-0">
      <JumpToBottomButton
        hasNewContent={hasNewContent}
        isAtBottom={isAtBottom}
        jumpToBottom={jumpToBottom}
      />

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
        commands={commands}
      />
    </div>
  );
}
