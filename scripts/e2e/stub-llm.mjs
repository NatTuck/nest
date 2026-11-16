/**
 * A stub model provider for the end-to-end suite.
 *
 * The suite creates its space, its agent and its message through the real UI, so
 * the agent needs a model that resolves and a provider that answers. There is no
 * real provider key on a CI runner and there should not be one: a real model
 * costs money, takes seconds, and fails for reasons that have nothing to do with
 * this repository. So this stands in for the provider — the external service —
 * and nothing else. Every workflow the suite covers is still the app's own.
 *
 * OpenAI-compatible, and only the two endpoints the app actually calls:
 *
 *   GET  /v1/models             the catalog the agent picks from
 *   POST /v1/chat/completions   SSE, one token-ish chunk per word
 *
 * The reply is fixed (`STUB_LLM_REPLY`, default "pong from the stub") so a spec
 * can wait for that exact text instead of sleeping. `STUB_LLM_DEBUG=1` logs each
 * request to stderr.
 */
import { createServer } from "node:http";

const PORT = Number(process.env.STUB_LLM_PORT || 4011);
const MODEL = process.env.STUB_LLM_MODEL || "stub-model";
const REPLY = process.env.STUB_LLM_REPLY || "pong from the stub";
const DEBUG = process.env.STUB_LLM_DEBUG === "1";

const log = (...args) => {
  if (DEBUG) console.error("[stub-llm]", ...args);
};

const sse = (body) => `data: ${JSON.stringify(body)}\n\n`;

const chunk = (delta, finishReason = null) =>
  sse({
    id: "chatcmpl-stub",
    object: "chat.completion.chunk",
    model: MODEL,
    choices: [{ index: 0, delta, finish_reason: finishReason }]
  });

/** The whole reply as SSE frames: a role frame, one frame per word, a stop
 *  frame, the usage frame the client asks for (`include_usage`), and `[DONE]`. */
function replyFrames() {
  const words = REPLY.split(/(?<=\s)/);
  return [
    chunk({ role: "assistant", content: "" }),
    ...words.map((word) => chunk({ content: word })),
    chunk({}, "stop"),
    sse({
      id: "chatcmpl-stub",
      object: "chat.completion.chunk",
      model: MODEL,
      choices: [],
      usage: {
        prompt_tokens: 16,
        completion_tokens: words.length,
        total_tokens: 16 + words.length
      }
    }),
    "data: [DONE]\n\n"
  ];
}

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": Buffer.byteLength(payload)
  });
  res.end(payload);
}

const server = createServer((req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  log(req.method, url.pathname);

  if (req.method === "GET" && url.pathname.endsWith("/models")) {
    return json(res, 200, {
      object: "list",
      data: [{ id: MODEL, object: "model", owned_by: "stub" }]
    });
  }

  if (req.method === "POST" && url.pathname.endsWith("/chat/completions")) {
    // Drain the request body: the connection is keep-alive and an unread body
    // would stall the next request on it.
    req.resume();
    req.on("end", () => {
      res.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive"
      });
      for (const frame of replyFrames()) res.write(frame);
      res.end();
    });
    return undefined;
  }

  return json(res, 404, { error: { message: `no stub for ${url.pathname}` } });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`stub model provider on http://127.0.0.1:${PORT}/v1 (${MODEL})`);
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
