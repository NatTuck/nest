/**
 * Mode selector — small dropdown shown next to the chat input when
 * an agent has more than one mode. Renders nothing for agents with
 * exactly one mode (e.g. legacy "chat"-only vocations).
 */
export function ModeSelector({ modes, value, onChange, disabled }) {
  if (!modes || modes.length <= 1) return null;

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
