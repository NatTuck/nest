/**
 * DecisionsAccordion — the space's questions for the user (#119).
 *
 * Every question's title is always on screen and exactly one body is open. The
 * open row is held by **id**, never by index: the whole list is resent on every
 * frame and a new question appends to it, so an index would slide the open body
 * onto a different question the moment one arrived. Keying the rows by id is
 * also what keeps React's DOM nodes — and any focus or half-typed answer in
 * them — in place across a frame.
 *
 * Resolving a question (save or drop) contracts it and opens the next one that
 * is still unanswered, wrapping at the end. That happens from the click that
 * resolved it and from nothing else: a frame that arrives must not move the row
 * the user is reading, which is why the advance lives in the store's
 * `markPaneDecision` rather than in a reconcile.
 *
 * An orphaned question — its asking agent is gone or archived — cannot be
 * answered at all, only dropped, so its body carries the reason and no answer
 * controls. A question the server refused to deliver for a transient reason
 * stays answerable and says why inline.
 */

import { useStore } from "../../store";
import {
  dropDecisions,
  explainDecision,
  sendDecisionAnswers,
} from "../../channels";
import { ChevronDown } from "../ChevronDown";

/** The badge on a title row: what state that question is in. */
function RowState({ isOpen, mark }) {
  if (mark === "save") {
    return (
      <span className="shrink-0 rounded bg-emerald-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-emerald-800">
        saved
      </span>
    );
  }
  if (mark === "drop") {
    return (
      <span className="shrink-0 rounded bg-gray-200 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-gray-700">
        dropped
      </span>
    );
  }
  if (isOpen) {
    return (
      <span className="shrink-0 rounded bg-sky-100 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-sky-800">
        open
      </span>
    );
  }
  return null;
}

/** The save/drop marks, which stay depressed until the answer or the send. */
function MarkButtons({ mark, showSave, canSave, onMark }) {
  return (
    <>
      {showSave && (
        <button
          type="button"
          aria-pressed={mark === "save"}
          disabled={!canSave}
          onClick={() => onMark("save")}
          className={[
            "rounded px-2 py-1 text-xs font-semibold transition-colors",
            mark === "save"
              ? "bg-emerald-600 text-white"
              : "bg-emerald-50 text-emerald-800 hover:bg-emerald-100",
            !canSave && "cursor-not-allowed opacity-50",
          ]
            .filter(Boolean)
            .join(" ")}
        >
          Save
        </button>
      )}
      <button
        type="button"
        aria-pressed={mark === "drop"}
        onClick={() => onMark("drop")}
        className={[
          "rounded px-2 py-1 text-xs font-semibold transition-colors",
          mark === "drop"
            ? "bg-gray-600 text-white"
            : "bg-gray-100 text-gray-700 hover:bg-gray-200",
        ].join(" ")}
      >
        Drop
      </button>
    </>
  );
}

/**
 * One question's body: the trade-offs, the suggested answers and the free-text
 * field, then the save/drop marks and the "explain more" control.
 */
function QuestionBody({
  decision,
  mark,
  draft,
  outcome,
  onDraft,
  onMark,
  onExplain,
}) {
  const orphaned = decision.orphaned === true || outcome?.kind === "orphaned";
  const orphanedReason =
    decision.orphanedReason ??
    (outcome?.kind === "orphaned" ? outcome.reason : null);
  const options = Array.isArray(decision.options) ? decision.options : null;
  const answer = typeof draft === "string" ? draft : "";

  return (
    <div className="space-y-2 border-t border-gray-100 bg-gray-50/60 px-3 pb-3 pt-2">
      <p className="whitespace-pre-wrap break-words text-sm text-gray-700">
        {typeof decision.body === "string" && decision.body.length > 0
          ? decision.body
          : "(no explanation was given)"}
      </p>
      <p className="text-[11px] text-gray-500">
        Asked by {decision.askedBy ?? "(an unidentified agent)"}
      </p>

      {decision.obsolete === true && (
        <p
          data-testid="decision-obsolete"
          className="rounded bg-amber-50 px-2 py-1 text-xs font-medium text-amber-800"
        >
          The agent marked this obsolete
          {decision.obsoleteReason
            ? `: ${decision.obsoleteReason}`
            : " (no reason was given)."}
        </p>
      )}

      {orphaned && (
        <p
          data-testid="decision-orphaned"
          className="rounded bg-red-50 px-2 py-1 text-xs font-medium text-red-700"
        >
          Cannot be answered
          {orphanedReason ? `: ${orphanedReason}` : " (no reason was given)."}{" "}
          It can only be dropped.
        </p>
      )}

      {outcome?.kind === "failed" && (
        <p
          data-testid="decision-failed"
          className="rounded bg-red-50 px-2 py-1 text-xs font-medium text-red-700"
        >
          Not delivered
          {outcome.reason ? `: ${outcome.reason}` : " (no reason was given)."}{" "}
          You can send it again.
        </p>
      )}

      {outcome?.kind === "explained" && (
        <p
          data-testid="decision-explained"
          className="rounded bg-sky-50 px-2 py-1 text-xs font-medium text-sky-800"
        >
          Asked the agent for more detail.
        </p>
      )}

      {!orphaned && options === null && (
        <p
          data-testid="decision-options-missing"
          className="rounded bg-red-50 px-2 py-1 text-xs font-semibold text-red-700"
        >
          Suggested answers: (missing from the payload)
        </p>
      )}

      {!orphaned && options !== null && (
        <>
          <div className="flex flex-wrap gap-1">
            {options.map((option) => (
              <button
                key={option}
                type="button"
                aria-pressed={answer === option}
                onClick={() => onDraft(option)}
                className={[
                  "rounded-full border px-2 py-1 text-xs transition-colors",
                  answer === option
                    ? "border-sky-500 bg-sky-100 font-semibold text-sky-900"
                    : "border-gray-300 bg-white text-gray-700 hover:border-sky-300 hover:bg-sky-50",
                ].join(" ")}
              >
                {option}
              </button>
            ))}
          </div>
          <textarea
            aria-label="Your answer"
            rows={2}
            value={answer}
            onChange={(event) => onDraft(event.target.value)}
            placeholder="Or write your own answer..."
            className="w-full resize-y rounded border border-gray-300 px-2 py-1 text-sm text-gray-800 focus:border-sky-400 focus:outline-none"
          />
        </>
      )}

      <div className="flex flex-wrap items-center gap-2">
        <MarkButtons
          mark={mark}
          showSave={!orphaned}
          canSave={answer.trim().length > 0}
          onMark={onMark}
        />
        {!orphaned && (
          <button
            type="button"
            onClick={onExplain}
            className="rounded px-2 py-1 text-xs font-semibold text-sky-700 transition-colors hover:bg-sky-50"
          >
            Explain more
          </button>
        )}
      </div>
    </div>
  );
}

export function DecisionsAccordion({ name, spaceId }) {
  const pane = useStore((state) => state.panes?.[spaceId]);

  if (!pane) return null;

  const { decisions, drafts, marks, outcomes } = pane;
  // `expandedId` is the row the user opened; until they open one it is the
  // first question, and a row that has been removed from the list falls back to
  // the first one rather than leaving the accordion closed.
  const expandedId = decisions.some(
    (decision) => decision.id === pane.expandedId,
  )
    ? pane.expandedId
    : (decisions[0]?.id ?? null);
  const markedCount = Object.keys(marks).length;

  const handleSend = () => {
    const answers = decisions
      .filter((decision) => marks[decision.id] === "save")
      .map((decision) => ({
        id: decision.id,
        answer: (drafts[decision.id] ?? "").trim(),
      }));
    const dropped = decisions
      .filter((decision) => marks[decision.id] === "drop")
      .map((decision) => decision.id);

    // The marks were the thing this push posts, so pressing send releases them
    // (the drafts stay, so a refused push can be retried).
    useStore.getState().clearPaneMarks(spaceId);

    if (answers.length > 0) sendDecisionAnswers(name, spaceId, answers);
    if (dropped.length > 0) dropDecisions(name, spaceId, dropped);
  };

  return (
    <section>
      <div className="sticky top-0 z-10 border-b border-gray-200 bg-white px-3 py-2">
        <div className="flex items-center justify-between gap-2">
          <h3 className="text-[11px] font-semibold uppercase tracking-wider text-gray-500">
            Questions ({decisions.length})
          </h3>
          <button
            type="button"
            onClick={handleSend}
            disabled={markedCount === 0}
            className={[
              "rounded px-2 py-1 text-xs font-semibold transition-colors",
              markedCount === 0
                ? "cursor-not-allowed bg-gray-100 text-gray-400"
                : "bg-sky-600 text-white hover:bg-sky-700",
            ].join(" ")}
          >
            Send answers{markedCount > 0 ? ` (${markedCount})` : ""}
          </button>
        </div>
        {pane.error && (
          <p
            data-testid="pane-error"
            className="mt-1 rounded bg-red-50 px-2 py-1 text-xs font-semibold text-red-700"
          >
            {pane.error}
          </p>
        )}
      </div>

      {decisions.length === 0 ? (
        <p className="px-3 py-3 text-xs text-gray-500">
          No questions right now.
        </p>
      ) : (
        <ol>
          {decisions.map((decision) => {
            const isOpen = decision.id === expandedId;

            return (
              <li
                key={decision.id}
                className="border-b border-gray-100 last:border-b-0"
              >
                <button
                  type="button"
                  aria-expanded={isOpen}
                  onClick={() =>
                    useStore.getState().setPaneExpanded(spaceId, decision.id)
                  }
                  className="flex w-full items-start gap-2 px-3 py-2 text-left transition-colors hover:bg-gray-50"
                >
                  <span className="mt-0.5 text-gray-400">
                    <ChevronDown rotated={isOpen} />
                  </span>
                  <span className="flex-1 text-sm font-medium text-gray-800">
                    {typeof decision.title === "string" &&
                    decision.title.length > 0
                      ? decision.title
                      : "(untitled question)"}
                  </span>
                  <RowState isOpen={isOpen} mark={marks[decision.id]} />
                </button>

                {isOpen && (
                  <QuestionBody
                    decision={decision}
                    mark={marks[decision.id]}
                    draft={drafts[decision.id]}
                    outcome={outcomes[decision.id]}
                    onDraft={(text) =>
                      useStore
                        .getState()
                        .setPaneDraft(spaceId, decision.id, text)
                    }
                    onMark={(mark) =>
                      useStore
                        .getState()
                        .markPaneDecision(spaceId, decision.id, mark)
                    }
                    onExplain={() =>
                      explainDecision(name, spaceId, decision.id)
                    }
                  />
                )}
              </li>
            );
          })}
        </ol>
      )}
    </section>
  );
}
