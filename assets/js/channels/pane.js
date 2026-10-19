/**
 * The right-hand pane's wire (#119 / #120): one `pane:state` frame carries the
 * whole state of the space's questions and the TODO lists, `pane:sync` asks for
 * it again, and three pushes act on the questions.
 *
 * Every helper updates the store from its own reply, so the components only
 * describe what the user did and never have to hold a channel. Split out of
 * `channels/agent.js` so that file stays under the source-line cap.
 */

import { agentChannels, getStore } from "./state";
import { errorText } from "../utils/errorText";

/**
 * The space a pane payload belongs to, or `null` when it names a different
 * space than the channel it arrived on.
 *
 * The channel's own space is what the entry is keyed by — an agent channel
 * belongs to exactly one space — so a payload that says otherwise is a
 * cross-space broadcast bug. Refusing it loudly turns that from state quietly
 * filed under the wrong space into a warning nobody can miss. A payload that
 * names no space is not a mismatch: the channel's space is the answer.
 */
export function paneFrameSpace(agentId, spaceId, payload) {
  const named = payload?.spaceId;
  if (named == null || named === spaceId) return spaceId;

  console.warn(
    `[agent:${agentId}] pane frame names space ${named} on the channel for space ${spaceId}. Refused.`,
  );
  return null;
}

/**
 * Ask for the pane's whole state. The agent channel's join calls this, so a
 * reload restores the pane; the reply is the same payload a `pane:state` frame
 * carries, and the store's `seq` guard makes an overlapping frame harmless.
 *
 * The reply goes to the store as-is: `setPaneState` is the one place that
 * decides a payload is unusable, and it warns when it refuses one. Guarding
 * here as well would only silence that warning, leaving a reload that got a
 * malformed reply with a permanently empty pane and a clean console.
 *
 * A no-op when the channel isn't connected.
 */
export function requestPaneSync(agentId, spaceId) {
  const channel = agentChannels.get(agentId);
  if (!channel || spaceId == null) return;

  channel.push("pane:sync", {}).receive("ok", (payload) => {
    const space = paneFrameSpace(agentId, spaceId, payload);
    if (space == null) return;
    getStore().setPaneState(space, payload);
  });
}

/**
 * Send the answers the user saved. `answers` is `[{id, answer}]`; the reply
 * names what landed, what the server refused while leaving the question in the
 * list (still answerable), what turned out orphaned (drop-only), and what was
 * removed with its answer lost. Each report is kept on its question, so the
 * pane can say what happened inline.
 */
export function sendDecisionAnswers(agentId, spaceId, answers) {
  const channel = agentChannels.get(agentId);
  if (!channel || spaceId == null) {
    getStore().setPaneError(spaceId, "Not connected to the agent.");
    return;
  }

  channel
    .push("decisions:answer", { answers })
    .receive("ok", (reply) => {
      getStore().applyPaneAnswerReply(spaceId, reply);
    })
    .receive("error", (err) => {
      getStore().setPaneError(
        spaceId,
        errorText(err, "Could not send the answers."),
      );
    })
    .receive("timeout", () => {
      getStore().setPaneError(spaceId, "Sending the answers timed out.");
    });
}

/**
 * Drop the questions the user marked drop. The reply carries nothing; the
 * server broadcasts the list without them, and that frame is the removal.
 */
export function dropDecisions(agentId, spaceId, ids) {
  const channel = agentChannels.get(agentId);
  if (!channel || spaceId == null) {
    getStore().setPaneError(spaceId, "Not connected to the agent.");
    return;
  }

  channel
    .push("decisions:drop", { ids })
    .receive("ok", () => {
      getStore().setPaneError(spaceId, null);
    })
    .receive("error", (err) => {
      getStore().setPaneError(
        spaceId,
        errorText(err, "Could not drop the questions."),
      );
    })
    .receive("timeout", () => {
      getStore().setPaneError(spaceId, "Dropping the questions timed out.");
    });
}

/**
 * Ask the asking agent for more detail on one question. The question stays
 * open, and the acknowledgement is marked on it so the click is not silent.
 */
export function explainDecision(agentId, spaceId, id) {
  const channel = agentChannels.get(agentId);
  if (!channel || spaceId == null) {
    getStore().setPaneError(spaceId, "Not connected to the agent.");
    return;
  }

  channel
    .push("decisions:explain", { id })
    .receive("ok", () => {
      getStore().setPaneExplained(spaceId, id);
    })
    .receive("error", (err) => {
      getStore().setPaneError(
        spaceId,
        errorText(err, "Could not ask for more detail."),
      );
    })
    .receive("timeout", () => {
      getStore().setPaneError(spaceId, "Asking for more detail timed out.");
    });
}
