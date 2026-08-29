/**
 * Inline error banner shown when a chat message send fails. Extracted
 * from `ChatPage`.
 */
export function SendErrorBanner({ message }) {
  if (!message) return null;
  return (
    <div className="bg-red-50 border border-red-200 rounded-lg p-3 mb-4">
      <p className="text-red-700 text-sm">{message}</p>
    </div>
  );
}
