import { describeConfigFileError } from "./chatErrors.js";

/**
 * One line for a failed push or save, whatever shape the failure came
 * in: a channel `error` reply is `{reason}` (a bare server enum such as
 * `forbidden`), a thrown `Error` is `{message}`, and a transport failure
 * can be either. `message` wins when both are present, because it is the
 * more specific of the two.
 *
 * `fallback` is the caller's own sentence, so a failure the server
 * explained nothing about still says what the click was trying to do.
 *
 * The one reply that outranks `message` is the `config_file_not_regular`
 * refusal (see `describeConfigFileError`): it is a bare enum plus the file it
 * is about, so the shared sentence is the only useful wording for it.
 */
export function errorText(err, fallback) {
  // A `config_file_not_regular` reply is the one reason a bare enum is
  // useless: the user has to know which file, and the remedy depends on the
  // `type` the server sent. `describeConfigFileError` is the single wording
  // for it, shared with the create-space and edit-agent paths, so it is asked
  // first rather than being flattened into `reason` below.
  return (
    describeConfigFileError(err) || err?.message || err?.reason || fallback
  );
}
