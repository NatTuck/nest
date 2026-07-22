/**
 * Three bouncing dots used as a "streaming/working" indicator.
 *
 * Configurable size and color via props so the same component
 * can be reused across contexts (thinking-block header uses
 * amber + small, ChatPage typing indicator uses blue/gray).
 */
export function StreamingDots({
  size = "sm",
  colorClass = "bg-gray-400",
  ariaLabel = "Working",
}) {
  const sizeClass = size === "lg" ? "w-2 h-2" : "w-1.5 h-1.5";

  return (
    <span className="inline-flex gap-1" role="status" aria-label={ariaLabel}>
      <span
        className={`${sizeClass} ${colorClass} rounded-full animate-bounce`}
        style={{ animationDelay: "0ms" }}
        aria-hidden="true"
      />
      <span
        className={`${sizeClass} ${colorClass} rounded-full animate-bounce`}
        style={{ animationDelay: "150ms" }}
        aria-hidden="true"
      />
      <span
        className={`${sizeClass} ${colorClass} rounded-full animate-bounce`}
        style={{ animationDelay: "300ms" }}
        aria-hidden="true"
      />
    </span>
  );
}
