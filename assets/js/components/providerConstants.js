/**
 * Shared constants for the Providers admin screen.
 */

import { nanoid } from "nanoid";

export const THINKING_LEVELS = ["off", "low", "medium", "high", "xhigh"];
export const PROTOCOLS = ["openai", "anthropic"];

/**
 * The two per-provider silence bounds, in seconds, that
 * `Nest.DotConfig` uses when a provider sets neither. Shown as the
 * placeholders of the editor's timeout inputs so an operator sees
 * what leaving a field blank means.
 *
 * The numbers duplicate `Nest.DotConfig.default_first_byte_timeout_seconds/0`
 * and `default_stream_idle_timeout_seconds/0` — the browser cannot read the
 * config file — and `test/nest/dot_config_js_defaults_test.exs` pins the two
 * together, so changing one without the other fails a test rather than leaving
 * the GUI quoting a stale default.
 */
export const DEFAULT_FIRST_BYTE_TIMEOUT_SECONDS = 900;
export const DEFAULT_STREAM_IDLE_TIMEOUT_SECONDS = 120;

/**
 * Generate a stable client-side id used only as a React key for list
 * items (providers/models). It never leaves the browser — `id` is
 * stripped from the save payload before it's sent to the server.
 */
export function makeId() {
  return nanoid();
}

export function emptyModel() {
  return {
    id: makeId(),
    name: "",
    context_limit: null,
    multi_modal: null,
    thinking_effort: null,
  };
}

export function emptyProvider() {
  return {
    id: makeId(),
    name: "",
    base_url: null,
    api_key: "",
    protocol: "openai",
    auto_models: false,
    tags: [],
    first_byte_timeout_seconds: null,
    stream_idle_timeout_seconds: null,
    default_context_limit: null,
    default_thinking_effort: null,
    probe_base_url: null,
    auto_probe: true,
    expose_models: false,
    probe_multimodal: false,
    models: [],
  };
}
