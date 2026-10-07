/**
 * Page titles.
 *
 * The browser tab must say which machine this instance is running on
 * (e.g. `vampire` vs `typhon`), so every page sets a title of the form
 * `{host} · {space} · {agent}`. The host comes first and is always
 * present; the page-specific parts are dropped when they don't apply.
 * There is deliberately no "Nest" in the title -- the tab icon carries
 * the app identity.
 */

import { useEffect } from "react";

/**
 * Shown in the title when the server did not report a usable host.
 * Per the project's transparency rule a value we don't have is made
 * visible, never silently dropped.
 */
export const MISSING_HOST = "[missing host]";

/** Parts of the title are joined by a space, a middle dot, and a space. */
export const TITLE_SEPARATOR = " · ";

/** Normalize the server-reported host, substituting `MISSING_HOST`. */
function resolveHost(host) {
  if (typeof host !== "string") return MISSING_HOST;
  const trimmed = host.trim();
  return trimmed === "" ? MISSING_HOST : trimmed;
}

/**
 * The host this instance runs on, as set by the server in
 * `window.NEST_CONFIG.host` (next to `sourceUrl`).
 */
function configuredHost() {
  return window.NEST_CONFIG?.host;
}

/**
 * Normalize one page-supplied segment, dropping anything that would
 * render as nothing (non-strings, empty strings, whitespace).
 */
function normalizeSegment(segment) {
  if (typeof segment !== "string") return null;
  const trimmed = segment.trim();
  return trimmed === "" ? null : trimmed;
}

/**
 * Pure title builder: the host, then every non-empty segment.
 *
 * @param {Array<string>} segments page-specific parts, in order
 * @param {unknown} [host] defaults to `window.NEST_CONFIG.host`
 * @returns {string}
 */
export function buildDocumentTitle(segments, host = configuredHost()) {
  const parts = segments.map(normalizeSegment).filter((part) => part !== null);
  return [resolveHost(host), ...parts].join(TITLE_SEPARATOR);
}

/**
 * Set the document title to `buildDocumentTitle(segments)` for as long
 * as the page is mounted.
 *
 * The effect depends on the *joined* title string, not on the array of
 * segments: callers pass a fresh array literal on every render, so an
 * array dependency would re-run the effect (and rewrite
 * `document.title`) on every single render.
 *
 * @param {Array<string>} segments page-specific parts, in order
 */
export function useDocumentTitle(segments) {
  const title = buildDocumentTitle(segments);

  useEffect(() => {
    document.title = title;
  }, [title]);
}
