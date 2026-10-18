/**
 * The space feed's pushes: its initial read and the composer's send.
 *
 * The feed (`/space/:slug`) is the space's note log. Its frames arrive on the
 * **lobby** channel, which is already subscribed to every space topic the user
 * can see — every `user_notes` insert broadcasts there
 * (`NestWeb.LobbyChannel.SpaceFeed`). So there is no feed channel to join and no
 * second socket: `user_note:created` is registered with the other lobby frames
 * in `./lobby`, and the two pushes below are the only additions.
 *
 * Split from `./lobby` so that file stays under the source-line cap, and because
 * these two are the feed's whole transport rather than part of the space
 * management surface.
 */

import { getStore, lobbyChannel } from "./state";
import { errorText } from "../utils/errorText";

/** The reason a push cannot even be attempted, as a sentence the feed shows. */
const NOT_CONNECTED = "Not connected: the notes cannot be loaded or sent.";

/**
 * Read the space's feed: `space_feed` → `{notes, modes, default_mode}`.
 *
 * The reply replaces the whole cache entry, so this is also the retry path after
 * a failed read and the resync after a reconnect. A failure — including the
 * channel not being up — leaves an `error` on the entry rather than an empty
 * list, because the feed must never show "nothing has been said" for a read that
 * did not happen.
 */
export function requestSpaceFeed(spaceId) {
  const store = getStore();
  store.setSpaceFeedLoading(spaceId);

  if (!lobbyChannel) {
    store.setSpaceFeedError(spaceId, NOT_CONNECTED);
    return;
  }

  lobbyChannel
    .push("space_feed", { space_id: spaceId })
    .receive("ok", (resp) => {
      getStore().setSpaceFeed(spaceId, resp);
    })
    .receive("error", (err) => {
      getStore().setSpaceFeedError(
        spaceId,
        errorText(err, "Could not load the notes in this space."),
      );
    })
    .receive("timeout", () => {
      getStore().setSpaceFeedError(
        spaceId,
        "The server did not answer: the notes could not be loaded.",
      );
    });
}

/**
 * Send one note from the human to `to` — a **query**, which is what obliges the
 * agent to answer (`Nest.Agents.send_note/6`).
 *
 * Nothing is written optimistically: the server persists the note and broadcasts
 * it, and that frame is what puts it in the feed. So the feed has one path for a
 * note whether it was sent from here or arrived from an agent, and a send that
 * failed leaves no phantom row behind.
 *
 * The send also answers the queries `to` had outstanding, so the banner clears
 * for that agent (`markSpaceQueriesAnswered`).
 */
export function sendSpaceNote(spaceId, to, content, mode, onOk, onError) {
  if (!lobbyChannel) {
    if (onError) onError(new Error(NOT_CONNECTED));
    return;
  }

  const payload = { space_id: spaceId, to, content };
  if (mode) payload.mode = mode;

  lobbyChannel
    .push("send_note", payload)
    .receive("ok", (resp) => {
      getStore().markSpaceQueriesAnswered(spaceId, to);
      if (onOk) onOk(resp);
    })
    .receive("error", (err) => {
      if (onError) onError(err);
    })
    .receive("timeout", () => {
      if (onError) onError(new Error("The server did not answer the send."));
    });
}
