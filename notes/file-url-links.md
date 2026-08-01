# `file://` URLs in chat messages render as `javascript:throw new Error(...)`

## The bug

When the LLM emits a markdown link to a local file — e.g.

```markdown
**[file:///home/nat/Documents/Sauna/sauna_floorplan.svg](file:///home/nat/Documents/Sauna/sauna_floorplan.svg)**
```

the chat-ui `Markdown` component renders it as a `<a>` with `href="file:///home/nat/Documents/Sauna/sauna_floorplan.svg"`. The link text is highlighted, but the rendered `href` reads

```
javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')
```

instead of the original `file:///` URL. Clicking the link throws an error.

## Root cause

Two layers of replacement, both on the same URL:

### 1. react-markdown's `uriTransformer`

The chat-ui `Markdown` component uses `react-markdown` under the hood. `react-markdown` runs every URL through a `uriTransformer` (defined at `react-markdown@8.0.7/lib/uri-transformer.js`):

```js
const protocols = ['http', 'https', 'mailto', 'tel']

export function uriTransformer(uri) {
  const url = (uri || '').trim()
  const first = url.charAt(0)

  if (first === '#' || first === '/') {
    return url
  }

  const colon = url.indexOf(':')
  if (colon === -1) {
    return url
  }

  let index = -1
  while (++index < protocols.length) {
    const protocol = protocols[index]
    if (
      colon === protocol.length &&
      url.slice(0, protocol.length).toLowerCase() === protocol
    ) {
      return url
    }
  }

  index = url.indexOf('?')
  if (index !== -1 && colon > index) return url

  index = url.indexOf('#')
  if (index !== -1 && colon > index) return url

  return 'javascript:void(0)'
}
```

The whitelist is hardcoded. Any URL whose protocol isn't in `['http', 'https', 'mailto', 'tel']` (and which isn't a relative URL, query, or hash fragment) is replaced with the literal string `'javascript:void(0)'`. The `file:` protocol is not in the list, so `file:///home/...` becomes `javascript:void(0)`.

This is the original purpose of the `uriTransformer` (from `react-markdown`'s security docs): "It's given a URL and cleans it, by allowing only `http:`, `https:`, `mailto:`, `tel:` protocols, returning `'javascript:void(0)'` for any other protocol." A safety default — but it blocks `file:`.

The chat-ui's `preprocessMedia` step (`@llamaindex/chat-ui/src/widgets/markdown.tsx:75-79`) strips `sandbox:`, `attachment:`, and `snt:` URL prefixes — a workaround for OpenAI's model quirks — but does not handle `file:`.

### 2. React 19's DOM `sanitizeURL`

After react-markdown rewrites the URL, React 19 mounts the `<a>` element. The `href` attribute on an `<a>` element flows through `setInitialDOMProperties` → `case "href":` → `setValueForAttribute` → `sanitizeURL("" + value)`. The `sanitizeURL` function (in `react-dom@19.2.6/cjs/react-dom-client.development.js:3166-3170`):

```js
function sanitizeURL(url) {
  return isJavaScriptProtocol.test("" + url)
    ? "javascript:throw new Error('React has blocked a javascript: URL as a security precaution.')"
    : url;
}
```

Where `isJavaScriptProtocol` (`react-dom-client.development.js:25135-25136`) is:

```js
isJavaScriptProtocol = /^[\u0000-\u001F ]*j[\r\n\t]*a[\r\n\t]*v[\r\n\t]*a[\r\n\t]*s[\r\n\t]*c[\r\n\t]*r[\r\n\t]*i[\r\n\t]*p[\r\n\t]*t[\r\n\t]*:/i
```

Matches any string that starts with `javascript:` (case-insensitive, allowing whitespace/control chars between letters). Since step 1 rewrote the URL to exactly `'javascript:void(0)'`, the regex matches, and `sanitizeURL` replaces it with the user-facing error message.

### Combined effect

For a markdown link `[label](file:///path)`:

1. react-markdown's `uriTransformer` rewrites the URL to `'javascript:void(0)'` (because `file:` is not in the allow-list).
2. React 19's `sanitizeURL` rewrites it to `'javascript:throw new Error(...)'` (because it now starts with `javascript:`).

The user sees the link rendered, but the `href` is the error string. Clicking throws.

## Solution

Wrap our markdown render in a thin custom component that uses `react-markdown` directly with a `uriTransformer` that whitelists `file:` (and any other safe protocols we need). The chat-ui's `Markdown` doesn't expose `uriTransformer`, so we have to replace it.

### Files to add / change

- `assets/js/components/Markdown.jsx` (new) — thin wrapper around `react-markdown` with our own `uriTransformer`. Mirrors the chat-ui's `Markdown` styling (the `prose dark:prose-invert` etc. classes). We don't need its `preprocessCitations` (we don't use citations) or `preprocessLaTeX` (we don't render LaTeX) — keeps the wrapper small.
- `assets/js/components/MessageContent.jsx` — swap `import { Markdown } from "@llamaindex/chat-ui/widgets"` for our new local `Markdown`.
- `assets/package.json` — add `react-markdown` (and optionally `remark-gfm`, `remark-math`, `rehype-katex`) as direct deps. They're already in `node_modules` through transitive deps, but listing them explicitly is cleaner.
- `assets/js/components/MessageContent.test.jsx` — mock our new `Markdown`, not the chat-ui one.

### `uriTransformer` shape

```js
const ALLOWED_PROTOCOLS = ['http', 'https', 'mailto', 'tel', 'file']

function uriTransformer(uri) {
  const url = (uri || '').trim()
  const first = url.charAt(0)
  if (first === '#' || first === '/') return url

  const colon = url.indexOf(':')
  if (colon === -1) return url

  for (const protocol of ALLOWED_PROTOCOLS) {
    if (
      colon === protocol.length &&
      url.slice(0, protocol.length).toLowerCase() === protocol
    ) {
      return url
    }
  }

  const queryIdx = url.indexOf('?')
  if (queryIdx !== -1 && colon > queryIdx) return url

  const hashIdx = url.indexOf('#')
  if (hashIdx !== -1 && colon > hashIdx) return url

  return 'javascript:void(0)'
}
```

Just the chat-ui's version with `file` added to the whitelist. All other behavior is unchanged — unknown protocols are still blocked.

### Tests to add

`test/nest/components/Markdown.test.jsx` (new):

1. Renders a markdown link with `file:///path` → `<a href="file:///path">label</a>` (no `javascript:` substitution).
2. Renders a markdown link with `https://example.com` → `<a href="https://example.com">label</a>` (unchanged).
3. Renders a markdown link with `javascript:alert(1)` → `<a href="javascript:void(0)">label</a>` (unknown protocol still blocked; react-markdown's safety).
4. Renders a relative markdown link `/path/to/file` → unchanged (relative URLs are not transformed).

In `MessageContent.test.jsx`, the `Markdown` mock import path changes (the chat-ui one is replaced with the local one). All existing tests should pass without changes to the test bodies.

### Risk

- The chat-ui's `Markdown` includes features we don't currently use (citations, document-info attachment rendering). If the codebase ever adopts those, we'll need a more elaborate replacement or a different approach (e.g. upstream a fix to `@llamaindex/chat-ui` that allows configuring the `uriTransformer`).
- The current `MessageContent.test.jsx` mocks the chat-ui's `Markdown`. After the swap, the mock path changes from `from "@llamaindex/chat-ui/widgets"` to `from "./Markdown"`. The mock body stays the same.
- `file:` URLs are not in any sandbox-restriction layer; if a future security policy restricts `file:` to specific workspaces, that would need to be added separately.
