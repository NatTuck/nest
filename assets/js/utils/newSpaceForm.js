/**
 * Pure helpers for the New Space form, extracted from `NewSpacePage` to
 * keep the page component under the source-line cap.
 */

export const DEFAULT_THINKING_LEVELS = [
  "off",
  "low",
  "medium",
  "high",
  "xhigh",
];

/**
 * The sandbox backends a space can be created with, in the order the
 * `<select>` offers them. The *server* is the authority on which values
 * are valid (and on what each one does); this list exists only so the
 * page and its tests agree on one set and one ordering.
 */
export const SANDBOX_BACKENDS = ["bwrap", "docker", "none"];

/** The backend a space gets unless the user picks another. */
export const DEFAULT_SANDBOX_BACKEND = "bwrap";

const SANDBOX_BACKEND_HELP = {
  bwrap:
    "Commands run in a bubblewrap sandbox; the sandbox caps (network and filesystem limits) are enforced.",
  docker:
    "Commands run in a Docker container shared by the space; only the workspace and the explicit .nest mounts are visible.",
  none: "Commands run directly on the host with no sandbox. The sandbox caps (network and filesystem limits) cannot be enforced.",
};

/**
 * Help text for a sandbox backend, rendered under the `<select>`. The
 * `none` text states plainly that the sandbox caps are unenforceable
 * there, because the commands run directly on the host.
 *
 * An unrecognised backend renders an obvious error rather than an empty
 * line: the value is constrained by `SANDBOX_BACKENDS` and by
 * `validateNewSpaceForm`, so reaching the fallback means the list here and
 * the value the form holds have drifted apart, which must not be silent.
 */
export function sandboxBackendHelp(backend) {
  return (
    SANDBOX_BACKEND_HELP[backend] ??
    `Unknown sandbox backend ${JSON.stringify(backend)}: this is a bug in the form, not a choice you can make.`
  );
}

/**
 * Resolve the thinking-level options for the selected model. Uses the
 * model's `thinking_levels` when present, else the full default set.
 */
export function resolveThinkingOptions(models, selectedModel) {
  const selectedModelData = models.find((m) => m.name === selectedModel);
  return selectedModelData?.thinking_levels?.length
    ? selectedModelData.thinking_levels
    : DEFAULT_THINKING_LEVELS;
}

/**
 * Validate the new-space form before firing the lobby push.
 * Returns a user-facing error message or `null` when submittable.
 *
 * @param {object} params
 * @param {string} params.name — the space name input.
 * @param {string} params.selectedBlueprint — the blueprint `<select>` value.
 * @param {string} params.selectedModel — the model `<select>` value.
 * @param {string} params.sandboxBackend — the sandbox `<select>` value.
 * @param {boolean} params.requiresWorkspace — whether the selected
 *   blueprint's root vocation expects a workspace.
 * @param {string} params.workspacePath — the workspace path input.
 * @returns {string | null}
 */
export function validateNewSpaceForm({
  name,
  selectedBlueprint,
  selectedModel,
  sandboxBackend,
  requiresWorkspace,
  workspacePath,
}) {
  if (!name?.trim()) {
    return "Please enter a space name";
  }
  if (!selectedBlueprint) {
    return "Please select a blueprint";
  }
  if (!selectedModel) {
    return "Please select a model";
  }
  if (!SANDBOX_BACKENDS.includes(sandboxBackend)) {
    return "Please select a sandbox backend";
  }
  if (requiresWorkspace && !workspacePath?.trim()) {
    return "Please specify a workspace path";
  }
  return null;
}
