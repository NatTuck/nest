/**
 * Whether a vocation's agents expect a workspace directory.
 *
 * **Always true**, now: every space has a workspace, because the `act` mode —
 * which every agent can be in — is what writes it. This used to be derived from
 * the vocation's mode caps (a vocation required a workspace iff any of its modes
 * wrote the symbolic `":workspace"` path), but the modes are universal code
 * constants (`Nest.Modes`), so there is nothing left to derive it from.
 *
 * It keeps taking the vocation because that is the shape its callers have; the
 * argument is deliberately ignored. Mirrors the backend's
 * `Nest.Vocations.requires_workspace?/1`, which is a constant for the same
 * reason.
 *
 * @param {object|null} _vocation — unused; every vocation's agents expect one.
 * @returns {boolean}
 */
export function vocationRequiresWorkspace(_vocation) {
  return true;
}
