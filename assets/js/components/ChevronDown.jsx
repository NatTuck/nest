/**
 * Small down-chevron icon, optionally rotated 180° to indicate
 * an expanded state. Used by collapsed/expandable UI surfaces
 * (truncated results, history markers, etc.).
 */
export function ChevronDown({ rotated = false }) {
  return (
    <svg
      className={`w-3 h-3 transition-transform ${rotated ? "rotate-180" : ""}`}
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
      aria-hidden="true"
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth={2}
        d="M19 9l-7 7-7-7"
      />
    </svg>
  );
}
