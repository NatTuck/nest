/**
 * Slash-command registry and parser.
 *
 * A command is declared once here (`{ name, description }`) and wired to
 * an action in `ChatPage`'s dispatch map. The parser and the autocomplete
 * are command-agnostic: adding a command is a registry entry plus, for a
 * server command, a dispatch entry and a channel `handle_in`.
 *
 * This module is pure (no channel/store imports) so it is unit-testable
 * in isolation.
 */

export const SLASH_COMMANDS = [
  {
    name: "compact",
    description: "Compact the conversation to free up context.",
  },
];

/**
 * Parse a composer submission into a registered slash command.
 *
 * Returns `{ name, args }` only when the trimmed text's first token is a
 * registered command name (e.g. `/compact`, or `/compact foo` → args
 * `"foo"`). `args` is the trimmed remainder after the command token, with
 * internal whitespace (including newlines) preserved. Returns `null` for
 * empty input, a bare `/`, an unknown command, or plain text — the caller
 * treats `null` as an ordinary message (no silent drop).
 */
export function parseSlashCommand(text) {
  const trimmed = (text ?? "").trim();
  if (!trimmed.startsWith("/")) return null;

  // The command token runs up to the first whitespace; the rest is args.
  const separatorIndex = trimmed.search(/\s/);
  const token =
    separatorIndex === -1 ? trimmed : trimmed.slice(0, separatorIndex);
  const name = token.slice(1);

  if (!SLASH_COMMANDS.some((command) => command.name === name)) return null;

  return {
    name,
    args: separatorIndex === -1 ? "" : trimmed.slice(separatorIndex).trim(),
  };
}

/**
 * The commands to suggest for the current composer text.
 *
 * Returns the registered commands whose name starts with the current
 * partial token, but only while the text is `/<partial>` (no whitespace,
 * so a spaced-out command suggests nothing). Returns `[]` for plain text
 * or a partial that already matches a command exactly (so the menu closes
 * once a command is complete).
 */
export function commandSuggestions(text, commands = SLASH_COMMANDS) {
  const trimmed = (text ?? "").trim();
  if (!trimmed.startsWith("/")) return [];

  const partial = trimmed.slice(1);

  return commands.filter(
    (command) => command.name !== partial && command.name.startsWith(partial),
  );
}
