/**
 * Shared constants for the Providers admin screen.
 */

export const THINKING_LEVELS = ["off", "low", "medium", "high", "xhigh"];
export const PROTOCOLS = ["openai", "anthropic"];

/**
 * Generate a stable client-side id used only as a React key for list
 * items (providers/models). It never leaves the browser — `id` is
 * stripped from the save payload before it's sent to the server.
 */
export function makeId() {
  return crypto.randomUUID();
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
    base_url: "",
    api_key: "",
    protocol: "openai",
    auto_models: false,
    tags: [],
    timeout_seconds: null,
    default_context_limit: null,
    default_thinking_effort: null,
    probe_base_url: null,
    auto_probe: true,
    expose_models: false,
    models: [],
  };
}
