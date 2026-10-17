/**
 * Mode selector — small dropdown shown next to the chat input when
 * an agent has more than one mode. Renders nothing for agents with
 * exactly one mode.
 *
 * Both the list and the value come from the server (`Nest.Modes` is the
 * authority on which modes exist, and the agent's `init` payload names the one
 * it is in): this component never holds a mode list of its own, so a mode the
 * server does not have cannot be picked here.
 */
export function ModeSelector({ modes, value, onChange, disabled }) {
  if (!modes || modes.length <= 1) return null;
  // A single mode is not worth a control, so that case renders nothing. A
  // *missing or unknown* value is different: it means we cannot say which mode
  // the agent is in, and AGENTS.md's transparency rule wants an obvious
  // indicator rather than nothing. A `<select>` with no value would display its
  // first option — a mode the agent is not in — and an empty space would hide
  // the fact that we do not know.
  if (!value || !modes.includes(value)) return <UnknownMode value={value} />;

  return (
    <select
      value={value ?? ""}
      onChange={(e) => onChange(e.target.value)}
      disabled={disabled}
      aria-label="Mode"
      className="px-3 py-3 border border-gray-300 rounded-lg bg-white text-sm font-medium text-gray-700 hover:bg-gray-50 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none disabled:bg-gray-100 disabled:cursor-not-allowed"
    >
      {modes.map((mode) => (
        <option key={mode} value={mode}>
          {mode}
        </option>
      ))}
    </select>
  );
}

/**
 * The "we do not know which mode this agent is in" indicator. It is a `role`
 * alert rather than a disabled select, because the useful thing to show is that
 * something is wrong — a disabled control would look like a choice the user
 * cannot make.
 */
function UnknownMode({ value }) {
  return (
    <span
      role="alert"
      title="The server reported no mode, or one this build does not know. This is a bug, not a choice you can make."
      className="px-3 py-3 border border-red-300 bg-red-50 text-red-700 rounded-lg text-sm font-medium"
    >
      {value == null ? "mode: (missing)" : `mode: unknown (${value})`}
    </span>
  );
}
