/**
 * Clipboard helpers.
 *
 * `copyToClipboard(text)` writes a string to the system clipboard,
 * preferring the modern async `navigator.clipboard.writeText` API and
 * falling back to a hidden `<textarea>` + `document.execCommand("copy")`
 * for environments where the modern API is missing (older iframes,
 * insecure HTTP contexts, some test runners).
 *
 * The async API requires a user gesture in some browsers, but the
 * call is always initiated from a click handler in our UI, so the
 * gesture requirement is satisfied at the call site.
 *
 * `useCopyToClipboard(timeoutMs)` is a React hook that returns
 * `[copied, copy]` where `copy(text)` writes the text and flips
 * `copied` to `true` for `timeoutMs` ms before reverting. Used by
 * `<CopyButton>` to swap the copy icon for a check icon for visual
 * feedback after a successful click.
 */

import { useCallback, useEffect, useRef, useState } from "react";

/**
 * Writes `text` to the system clipboard. Resolves `true` on success,
 * `false` on failure. Never throws — a clipboard failure is logged
 * with a `[NEST REGRESSION]` prefix and reported via the boolean
 * return so callers can decide what (if anything) to do.
 */
export async function copyToClipboard(text) {
  if (typeof text !== "string") return false;

  if (typeof navigator !== "undefined" && navigator.clipboard) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (err) {
      console.error(
        "[NEST REGRESSION] navigator.clipboard.writeText failed; falling back",
        err,
      );
    }
  }

  return legacyCopy(text);
}

function legacyCopy(text) {
  if (typeof document === "undefined") return false;
  const textarea = document.createElement("textarea");
  textarea.value = text;
  textarea.setAttribute("readonly", "");
  textarea.style.position = "absolute";
  textarea.style.left = "-9999px";
  textarea.style.top = "0";
  document.body.appendChild(textarea);
  textarea.select();
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } catch (err) {
    console.error("[NEST REGRESSION] document.execCommand('copy') threw", err);
    ok = false;
  }
  document.body.removeChild(textarea);
  return ok;
}

/**
 * React hook returning `[copied, copy]`:
 *   - `copied` is `true` for `timeoutMs` ms after the most recent
 *     successful `copy(text)` call, then reverts to `false`.
 *   - `copy(text)` writes to the clipboard and flips `copied` true.
 *
 * The timer is held in a ref so successive clicks within the timeout
 * window reset the timer cleanly (the previous timeout is cleared
 * before a new one is scheduled), and so a click after `copied` has
 * reverted starts a fresh window.
 */
export function useCopyToClipboard(timeoutMs = 2000) {
  const [copied, setCopied] = useState(false);
  const timerRef = useRef(null);

  useEffect(
    () => () => {
      if (timerRef.current !== null) {
        clearTimeout(timerRef.current);
      }
    },
    [],
  );

  const copy = useCallback(
    async (text) => {
      const ok = await copyToClipboard(text);
      if (!ok) return false;
      setCopied(true);
      if (timerRef.current !== null) {
        clearTimeout(timerRef.current);
      }
      timerRef.current = setTimeout(() => {
        setCopied(false);
        timerRef.current = null;
      }, timeoutMs);
      return true;
    },
    [timeoutMs],
  );

  return [copied, copy];
}
