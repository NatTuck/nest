/**
 * Initial loading state shown while the agent channel's first join is in
 * flight. Extracted from `ChatPage`.
 */
export function ChatLoading() {
  return (
    <div className="flex items-center justify-center h-full">
      <div className="flex flex-col items-center gap-4">
        <div className="animate-spin rounded-full h-12 w-12 border-b-2 border-blue-600" />
        <p className="text-gray-600">Loading agent...</p>
      </div>
    </div>
  );
}
