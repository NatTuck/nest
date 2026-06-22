/**
 * NotificationBanner component — shows a dismissible amber
 * banner for system notifications (non-error). The notification
 * shape is `{ message: string }`; the banner renders nothing
 * when `notification` is `null`.
 */
export function NotificationBanner({ notification, onClose }) {
  if (!notification) return null;

  return (
    <div className="bg-amber-50 border-l-4 border-amber-400 p-4 mb-4">
      <div className="flex items-start justify-between">
        <div className="flex items-start">
          <svg
            className="h-5 w-5 text-amber-400 mt-0.5 mr-3 flex-shrink-0"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
            />
          </svg>
          <p className="text-amber-800 text-sm">{notification.message}</p>
        </div>
        <button
          type="button"
          onClick={onClose}
          className="ml-4 text-amber-400 hover:text-amber-600 transition-colors flex-shrink-0"
          aria-label="Dismiss notification"
        >
          <svg
            className="h-5 w-5"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            aria-hidden="true"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M6 18L18 6M6 6l12 12"
            />
          </svg>
        </button>
      </div>
    </div>
  );
}
