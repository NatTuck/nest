/**
 * TodoList — the open agent's own TODO list (#120), read-only.
 *
 * The pane is a status surface: the agent owns the list and the human watches
 * it, so there is nothing to click here. The list arrives inside the space's
 * `pane:state` payload keyed by agent name, and the pane shows only the list of
 * the agent whose page is open.
 *
 * The three statuses are the ones the tools write. A status the pane does not
 * know is rendered as an explicit unknown rather than being hidden or shown as
 * a plausible-looking default: an invented status would tell the user the agent
 * is at a stage it never claimed.
 */

const STATUSES = {
  pending: { label: "pending", chip: "bg-gray-100 text-gray-700" },
  in_progress: { label: "in progress", chip: "bg-sky-100 text-sky-800" },
  done: { label: "done", chip: "bg-emerald-100 text-emerald-800" },
};

/** The counts that make a long list readable at a glance: `2 pending · 1 done`. */
function summary(items) {
  return Object.entries(STATUSES)
    .map(([status, meta]) => ({
      label: meta.label,
      count: items.filter((item) => item?.status === status).length,
    }))
    .filter((entry) => entry.count > 0)
    .map((entry) => `${entry.count} ${entry.label}`)
    .join(" · ");
}

function StatusChip({ status }) {
  const known = STATUSES[status];

  if (!known) {
    return (
      <span
        data-testid="todo-unknown-status"
        className="mt-0.5 shrink-0 rounded bg-red-100 px-1.5 py-0.5 font-mono text-[10px] font-semibold text-red-700"
      >
        {typeof status === "string" && status.length > 0
          ? `unknown: ${status}`
          : "(no status)"}
      </span>
    );
  }

  return (
    <span
      className={`mt-0.5 shrink-0 rounded px-1.5 py-0.5 font-mono text-[10px] font-semibold ${known.chip}`}
    >
      {known.label}
    </span>
  );
}

/**
 * One key per row. The wire carries no id for a TODO item and the same text can
 * legitimately appear twice (an agent may list the same step for two tasks), so
 * the key is the text plus its occurrence number within the list — stable while
 * the list holds still, and not an array index, which a reorder would reuse for
 * a different row.
 */
function rowsFor(items) {
  const seen = new Map();
  return items.map((item) => {
    const text =
      typeof item?.text === "string" && item.text.length > 0
        ? item.text
        : "(no text)";
    const occurrence = (seen.get(text) ?? 0) + 1;
    seen.set(text, occurrence);
    return { item, text, key: `${text}#${occurrence}` };
  });
}

export function TodoList({ todos, agentName }) {
  const missing = todos === null || todos === undefined;
  const items = Array.isArray(todos?.[agentName]) ? todos[agentName] : [];
  const counts = summary(items);
  const rows = rowsFor(items);

  return (
    <section className="border-b border-gray-200 px-3 py-3">
      <h3 className="text-[11px] font-semibold uppercase tracking-wider text-gray-500">
        TODO{missing ? "" : ` (${items.length})`}
      </h3>

      {missing ? (
        // The wire always carries the map (empty when nothing is listed), so a
        // payload without one is a contract violation, not "no TODOs".
        <p
          data-testid="todo-missing"
          className="mt-1 rounded bg-red-50 px-2 py-1 text-xs font-semibold text-red-700"
        >
          The pane state carried no TODO lists.
        </p>
      ) : items.length === 0 ? (
        <p className="mt-1 text-xs text-gray-500">
          No TODO items for {agentName}.
        </p>
      ) : (
        <>
          <ul className="mt-1 space-y-1">
            {rows.map(({ item, text, key }) => (
              <li key={key} className="flex items-start gap-2 text-sm">
                <StatusChip status={item?.status} />
                <span
                  className={
                    item?.status === "done"
                      ? "text-gray-400 line-through"
                      : "text-gray-800"
                  }
                >
                  {text}
                </span>
              </li>
            ))}
          </ul>
          {counts && <p className="mt-1 text-[11px] text-gray-500">{counts}</p>}
        </>
      )}
    </section>
  );
}
