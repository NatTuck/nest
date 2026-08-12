/**
 * Whether a vocation's agents expect a workspace directory.
 *
 * Mirrors the backend's `Vocations.requires_workspace?/1`: a vocation
 * requires a workspace iff any of its modes writes to the symbolic
 * `":workspace"` path. Used by the new-space form to show the workspace
 * input only for blueprints whose root vocation needs one.
 *
 * @param {object|null} vocation — a vocation from the store (with a
 *   `modes` map: `{ modeName: { caps: { fs: { write: string[] } } } }`).
 * @returns {boolean}
 */
export function vocationRequiresWorkspace(vocation) {
  if (!vocation?.modes) return false;
  return Object.values(vocation.modes).some(
    (mode) => mode?.caps?.fs?.write?.includes(":workspace") ?? false,
  );
}
