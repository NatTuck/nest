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
 * @param {boolean} params.requiresWorkspace — whether the selected
 *   blueprint's root vocation expects a workspace.
 * @param {string} params.workspacePath — the workspace path input.
 * @returns {string | null}
 */
export function validateNewSpaceForm({
  name,
  selectedBlueprint,
  selectedModel,
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
  if (requiresWorkspace && !workspacePath?.trim()) {
    return "Please specify a workspace path";
  }
  return null;
}
