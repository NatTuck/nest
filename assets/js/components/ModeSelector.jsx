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
  // Nothing to show until the server has said which mode the agent is in.
  // Without this the `<select>` would display its first option while the value
  // it was handed is absent — i.e. it would show a mode the agent is not in.
  if (!value || !modes.includes(value)) return null;

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
