/**
 * ToolResults component — displays the results of tool calls in
 * a tool message. Each result shows its name, its state, the
 * arguments, and its content.
 *
 * The badge is not a two-way success/failure switch. A result can
 * carry a `state` the `is_error` flag cannot express: a call the
 * machine moved to the background (issue #36) has produced no result
 * yet, so `is_error: false` would badge it "Success" — an assertion
 * the data does not support. The result's own `state` decides first,
 * and a state this build does not know is rendered as such rather
 * than being quietly read as a success or a failure.
 */
import { TruncatedResult } from "./TruncatedResult";
import { sortArgumentsForDisplay } from "../utils/argumentDisplay";

// The wire's `state` value for a call whose result has not arrived yet.
const BACKGROUNDED = "backgrounded";

const STATES = {
  success: {
    box: "bg-green-50 border-green-200",
    text: "text-green-700",
    content: "text-green-600",
    icon: "M5 13l4 4L19 7",
    iconLabel: "Success checkmark icon",
  },
  error: {
    box: "bg-red-50 border-red-200",
    text: "text-red-700",
    content: "text-red-600",
    icon: "M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z",
    iconLabel: "Error icon",
  },
  backgrounded: {
    box: "bg-sky-50 border-sky-200",
    text: "text-sky-700",
    content: "text-sky-600",
    icon: "M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z",
    iconLabel: "Backgrounded icon",
  },
  unknown: {
    box: "bg-amber-50 border-amber-200",
    text: "text-amber-700",
    content: "text-amber-600",
    icon: "M12 9v2m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z",
    iconLabel: "Unknown state icon",
  },
};

/** The state to badge, and the label that states it. */
function resultState(result) {
  if (result.state === BACKGROUNDED) {
    return { style: STATES.backgrounded, label: "Backgrounded" };
  }
  if (result.state) {
    // An unrecognised state is shown verbatim: it is data this build
    // cannot interpret, not an absent field to fall back from.
    return { style: STATES.unknown, label: `Unknown state (${result.state})` };
  }
  return result.is_error
    ? { style: STATES.error, label: "Error" }
    : { style: STATES.success, label: "Success" };
}

export function ToolResults({ toolResults }) {
  if (!toolResults || toolResults.length === 0) return null;

  return (
    <div className="mt-3 space-y-2">
      {toolResults.map((result) => {
        const { style, label } = resultState(result);

        return (
          <div
            key={result.tool_call_id}
            className={`border rounded-lg p-3 ${style.box}`}
          >
            <div
              className={`flex items-center gap-2 font-medium text-sm ${style.text}`}
            >
              <svg
                className="w-4 h-4"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
                aria-label={style.iconLabel}
              >
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={2}
                  d={style.icon}
                />
              </svg>
              <span>
                {label}: {result.name}
              </span>
            </div>
            {result.arguments && Object.keys(result.arguments).length > 0 && (
              <TruncatedResult
                content={JSON.stringify(
                  sortArgumentsForDisplay(result.arguments),
                  null,
                  2,
                )}
                className="text-purple-600"
              />
            )}
            {result.content && (
              <TruncatedResult
                content={result.content}
                className={style.content}
              />
            )}
          </div>
        );
      })}
    </div>
  );
}
