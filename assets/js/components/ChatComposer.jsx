/**
 * The chat input area with the floating "Jump to latest" button above it.
 * Positioned in the column's coordinate space (not inside the scroll
 * container) so it stays visible regardless of which ancestor scrolls.
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
  onModeRestore,
  history,
  commands,
  hasNewContent,
  isAtBottom,
  jumpToBottom,
}) {
  return (
    <div className="relative">
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
        onModeRestore={onModeRestore}
        history={history}
        commands={commands}
      />
    </div>
  );
}
