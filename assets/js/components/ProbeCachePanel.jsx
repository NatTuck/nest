/**
 * The multimodal probe cache's status panel, at the top of the
 * providers page, with the model-rescan button beside its one
 * destructive action.
 *
 * `Nest.LLM.MultimodalCache` remembers whether a model accepts images
 * across restarts, so the panel's job is to make that memory visible —
 * how many verdicts it holds, how old the oldest one is, and which file
 * they live in — and to let the user throw it away.
 *
 * The panel is admin-only by construction, not by hiding: the page it
 * lives on redirects non-admins to `/spaces`, and the server refuses
 * both events on its own, so a clear can only ever come from an admin.
 * Its one destructive action takes two clicks — the first arms it, the
 * second clears — because it sits a gap away from the harmless rescan.
 *
 * The stats come from the lobby: `probe_cache_stats` frames land in the
 * store, and the panel asks for a fresh copy when it appears. Anything
 * the server has not told us renders as an explicit unknown (a missing
 * count, a missing path), never as an empty cache or a blank line: the
 * user is about to clear this thing, so "we don't know what is in
 * there" is exactly what must not be shown as "there is nothing".
 */

import { useEffect, useState } from "react";
import { useStore } from "../store";
import { clearProbeCache, requestProbeCacheStats } from "../channels";
import { errorText } from "../utils/errorText";
import { RescanButton } from "./RescanButton";

// Largest whole unit first: `formatAge` takes the first one the duration
// reaches, so "3 days" never comes out as "72 h".
const AGE_UNITS = [
  [86400, "day"],
  [3600, "h"],
  [60, "min"],
];

export function ProbeCachePanel({ isRescanning, onRescan }) {
  const stats = useStore((state) => state.probeCacheStats);
  const [clearing, setClearing] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState(null);

  // The panel is the only reader of the cache's stats, so it fetches its
  // own copy when it appears rather than making the page fetch for it.
  // Later copies arrive unprompted (`probe_cache_stats` broadcast) or
  // from a clear's reply.
  useEffect(() => {
    requestProbeCacheStats();
  }, []);

  // The clear is destructive and irreversible, so it takes two clicks:
  // the first arms it (and the label says so), the second clears. Losing
  // focus disarms it, so a click anywhere else is a way out.
  const handleClear = () => {
    if (!confirming) {
      setConfirming(true);
      return;
    }

    setConfirming(false);
    setClearing(true);
    setError(null);

    clearProbeCache(
      () => setClearing(false),
      (err) => {
        setError(errorText(err, "Failed to clear the probe cache"));
        setClearing(false);
      },
    );
  };

  return (
    <section className="mb-8 rounded-lg border border-gray-200 bg-gray-50 p-5">
      <div className="flex flex-wrap items-start justify-between gap-3 mb-3">
        <h2 className="text-sm font-semibold text-gray-900">
          Multimodal probe cache
        </h2>
        <div className="flex items-center gap-3">
          <RescanButton
            isRescanning={isRescanning}
            isCreating={false}
            onClick={onRescan}
          />
          <span aria-hidden="true" className="h-5 w-px bg-gray-300" />
          <button
            type="button"
            onClick={handleClear}
            onBlur={() => setConfirming(false)}
            disabled={clearing}
            className={`px-3 py-1.5 rounded-md text-xs font-medium border transition-all ${clearButtonClass(clearing, confirming)}`}
          >
            {buttonLabel({ clearing, confirming, stats })}
          </button>
        </div>
      </div>

      <p className="text-sm text-gray-600 mb-3">
        Whether a model accepts images is learned by probing it. Verdicts are
        remembered here, so each model is probed once — clearing the cache makes
        the next scan re-probe every opted-in model (2–12 s each). The count is
        every verdict on file, including any whose provider endpoint has since
        changed and which the next scan would probe again.
      </p>

      <p
        className={`text-xs break-all ${
          stats ? "text-gray-600" : "text-amber-700 font-medium"
        }`}
      >
        {statsSummary(stats)}
      </p>

      {error && <p className="mt-3 text-xs text-red-700">{error}</p>}
    </section>
  );
}

/**
 * The clear button's label: armed (`confirmLabel`), in flight, or idle.
 */
function buttonLabel({ clearing, confirming, stats }) {
  if (clearing) return "Clearing…";
  if (confirming) return confirmLabel(stats);
  return clearLabel(stats);
}

/**
 * The armed label. It has to read as a different button from the one
 * just clicked, and it keeps the count, because that is what the second
 * click destroys.
 */
function confirmLabel(stats) {
  if (typeof stats?.entries !== "number") {
    return "Click again to clear (state unknown)";
  }
  if (stats.entries === 0) {
    return "Click again to clear (empty)";
  }

  return `Click again to clear (${entryCount(stats.entries)})`;
}

/**
 * The clear button's classes: grey while the push is in flight, solid
 * red once armed, quiet red before that.
 */
function clearButtonClass(clearing, confirming) {
  if (clearing) {
    return "bg-gray-100 text-gray-400 border-gray-200 cursor-not-allowed";
  }
  if (confirming) {
    return "bg-red-600 text-white border-red-600 hover:bg-red-700 active:bg-red-800";
  }

  return "bg-red-50 text-red-700 border-red-200 hover:bg-red-100 hover:border-red-300 active:bg-red-200";
}

/**
 * The clear button's idle label, carrying the stats: the user is about
 * to destroy exactly these entries, so the count and the age of the
 * oldest one belong on the button, not only in the copy beside it. A
 * stat the server has not sent renders as `state unknown` — never as
 * `empty`, which would be a claim we cannot make.
 */
function clearLabel(stats) {
  if (typeof stats?.entries !== "number") {
    return "Clear probe cache (state unknown)";
  }
  if (stats.entries === 0) {
    return "Clear probe cache (empty)";
  }

  return `Clear probe cache (${entryCount(stats.entries)}, ${oldestText(stats)})`;
}

/**
 * The line under the description: what is cached, how old it is, and
 * where it lives. Every part reports its own absence, so a partially
 * missing stats map still tells the user which part is missing.
 */
function statsSummary(stats) {
  if (!stats) {
    return "Cache state unknown — the lobby has not reported it.";
  }

  const parts = [entriesText(stats)];
  if (typeof stats.entries === "number" && stats.entries > 0) {
    parts.push(oldestText(stats));
  }
  parts.push(stats.path || "cache file path unknown");

  return parts.join(" · ");
}

function entriesText(stats) {
  if (typeof stats.entries !== "number") return "entry count unknown";
  if (stats.entries === 0) return "no cached verdicts";
  return entryCount(stats.entries);
}

function entryCount(entries) {
  return `${entries} ${entries === 1 ? "entry" : "entries"}`;
}

function oldestText(stats) {
  const age = formatAge(stats.oldest_age_s);
  return age === null ? "oldest age unknown" : `oldest ${age}`;
}

/**
 * A duration in the largest whole unit that still reads as a number the
 * user can act on ("3 days", not "259200 s"). `null` for anything that
 * is not a number, so the caller can report it as unknown rather than
 * print NaN.
 */
function formatAge(seconds) {
  if (typeof seconds !== "number" || Number.isNaN(seconds)) return null;

  const [size, unit] = AGE_UNITS.find(
    ([unitSeconds]) => seconds >= unitSeconds,
  ) ?? [1, "s"];
  const value = Math.floor(seconds / size);

  if (unit === "day") return `${value} ${value === 1 ? "day" : "days"}`;
  return `${value} ${unit}`;
}
