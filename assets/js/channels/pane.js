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
 * Ask for the pane's whole state. The agent channel's join calls this, so a
 * reload restores the pane; the reply is the same payload a `pane:state` frame
 * carries, and the store's `seq` guard makes an overlapping frame harmless.
 *
 * A no-op when the channel isn't connected.
 */
export function requestPaneSync(agentId, spaceId) {
  const channel = agentChannels.get(agentId);
  if (!channel || spaceId == null) return;

  channel.push("pane:sync", {}).receive("ok", (payload) => {
    // The reply is the same frame a push carries. A reply that is not one is
    // not applied: the pane keeps what it already has, and the next frame
    // brings it up to date — there is nothing to warn about, because nothing
    // on screen is stale and nothing was lost.
    if (typeof payload?.seq !== "number") return;
    getStore().setPaneState(spaceId, payload);
  });
}

/**
 * Send the answers the user saved. `answers` is `[{id, answer}]`; the reply
 * names what was delivered, what the server refused for a transient reason
 * (still answerable) and what turned out orphaned (drop-only). The two
 * refusals are kept on the question, so the pane can say why inline.
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
