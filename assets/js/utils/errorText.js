/**
 * One line for a failed push or save, whatever shape the failure came
 * in: a channel `error` reply is `{reason}` (a bare server enum such as
 * `forbidden`), a thrown `Error` is `{message}`, and a transport failure
 * can be either. `message` wins when both are present, because it is the
 * more specific of the two.
 *
 * `fallback` is the caller's own sentence, so a failure the server
 * explained nothing about still says what the click was trying to do.
 */
export function errorText(err, fallback) {
  return err?.message || err?.reason || fallback;
}
