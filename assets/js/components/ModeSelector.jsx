/**
 * Mode selector — the control next to the chat input when an agent has more
 * than one mode. Renders nothing for agents with exactly one mode.
 *
 * Both the list and the value come from the server (`Nest.Modes` is the
 * authority on which modes exist, and the agent's `init` payload names the one
 * it is in): this component never holds a mode list of its own, so a mode the
 * server does not have cannot be picked here.
 *
 * Two controls, one per side of `lg`:
 *
 *   * from `lg` up, the `<select>` this component has always been;
 *   * below `lg`, a segmented toggle (`ModeToggle`). `Nest.Modes.names/0` is a
 *     two-value catalogue (`plan`, `act`), so the select was a full-screen wheel
 *     picker in exchange for one bit of choice, and on a 390px composer row it
 *     also cost the field ~75px. Two buttons show both modes at once — a closed
 *     select cannot show the reader what the alternative *is* — and switch in
 *     one tap.
 *
 * The two are never both visible: the toggle is `lg:hidden` and the select is
 * `max-lg:hidden`. If the catalogue ever grows past a handful of values this
 * has to become a real menu rather than a wider toggle; it is a code constant in
 * `Nest.Modes`, which is why a two-way toggle is the honest shape today.
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
    <>
      <ModeToggle
        modes={modes}
        value={value}
        onChange={onChange}
        disabled={disabled}
      />
      <select
        value={value ?? ""}
        onChange={(e) => onChange(e.target.value)}
        disabled={disabled}
        aria-label="Mode"
        className="px-3 py-3 border border-gray-300 rounded-lg bg-white text-sm font-medium text-gray-700 hover:bg-gray-50 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none disabled:bg-gray-100 disabled:cursor-not-allowed max-lg:hidden"
      >
        {modes.map((mode) => (
          <option key={mode} value={mode}>
            {mode}
          </option>
        ))}
      </select>
    </>
  );
}

/**
 * The phone's mode control: one button per mode, the current one filled.
 *
 * `aria-pressed` on each button is what makes it a toggle group rather than a
 * pair of unlabelled buttons: the `fieldset` says what the group is, and each
 * button says whether it is the one in force. Not a radio group: picking a mode
 * does not submit anything — it sets a draft the next message carries.
 */
function ModeToggle({ modes, value, onChange, disabled }) {
  return (
    <fieldset
      aria-label="Agent mode"
      className="m-0 flex min-w-0 shrink-0 items-stretch overflow-hidden rounded-lg border border-gray-300 bg-white p-0 text-sm font-medium text-gray-700 lg:hidden"
    >
      {modes.map((mode) => (
        <button
          key={mode}
          type="button"
          onClick={() => onChange(mode)}
          disabled={disabled}
          aria-pressed={mode === value}
          className={`px-3 py-3 transition-colors disabled:cursor-not-allowed ${
            mode === value
              ? "bg-blue-600 text-white"
              : "hover:bg-gray-50 disabled:bg-gray-100"
          }`}
        >
          {mode}
        </button>
      ))}
    </fieldset>
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
