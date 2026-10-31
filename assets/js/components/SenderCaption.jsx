/**
 * Who spoke: the caption above one body of a multi-body row, and the reply
 * marker that a header can carry.
 *
 * The `[From … | mode: …]` header states three facts (`utils/header.js`), and
 * this is where two of them are drawn — the sender, and `, agents-send reply
 * required`. The mode is the row's badge and stays row-level.
 *
 * **Nothing is shown twice.** A row holding several bodies (a drained batch, a
 * backgrounded command's notice plus its output) captions each body, because
 * the senders differ; a single-body row states its sender once, in the row
 * label (`rowAppearance`), and gets no caption. The reply marker follows the
 * same rule: per body when there are several, row-level when there is one.
 *
 * Both draw from `senderClass`, so a sender looks the same wherever it appears.
 */
import { senderClass, senderLabel } from "../utils/header.js";

/** The `, agents-send reply required` clause, as a chip. */
export function ReplyRequiredChip() {
  return (
    <span className="text-[10px] px-1.5 py-0.5 rounded-full bg-amber-100 text-amber-800 font-medium">
      reply required
    </span>
  );
}

/** One body's sender (and its reply marker, when its header carries one). */
export function SenderCaption({ header }) {
  const { sender, replyRequired } = header;
  const { avatar } = senderClass(sender);

  return (
    <div className="flex items-center gap-2 mb-1">
      <span
        className={`text-[10px] px-1.5 py-0.5 rounded-full font-medium ${avatar}`}
      >
        {senderLabel(sender)}
      </span>
      {replyRequired && <ReplyRequiredChip />}
    </div>
  );
}
