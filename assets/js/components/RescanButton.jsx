/**
 * "Rescan providers" button used by the New Space form's model picker.
 * Extracted from `NewSpacePage` to keep that file under the source-line cap.
 */
export function RescanButton({ isRescanning, isCreating, onClick }) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={isRescanning || isCreating}
      aria-label="Rescan providers"
      className={`
        inline-flex items-center gap-2 px-3 py-1.5 rounded-md
        text-xs font-medium border transition-all
        ${
          isRescanning || isCreating
            ? "bg-gray-100 text-gray-400 border-gray-200 cursor-not-allowed"
            : "bg-amber-50 text-amber-800 border-amber-200 hover:bg-amber-100 hover:border-amber-300 active:bg-amber-200"
        }
      `}
    >
      {isRescanning ? (
        <>
          <svg
            className="animate-spin h-3.5 w-3.5"
            fill="none"
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
            />
            <path
              className="opacity-75"
              fill="currentColor"
              d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
            />
          </svg>
          Rescanning…
        </>
      ) : (
        "Rescan providers"
      )}
    </button>
  );
}
