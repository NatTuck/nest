import { expect } from "vitest";
import * as matchers from "@testing-library/jest-dom/matchers";

// Add jest-dom matchers to Vitest
expect.extend(matchers);

// Ensure jsdom globals are available
if (typeof document === "undefined") {
  throw new Error("jsdom environment not loaded. Check vitest config.");
}

// jsdom has no layout engine and does not implement `scrollIntoView`, which
// `useScrollToBottom` calls when it follows new content. A no-op is the right
// stub: the hook's own tests fabricate element metrics and assert on
// `scrollTop`, so they do not depend on this — but any *page* that renders the
// hook would throw without it, which is every page with a scrollable feed.
if (typeof Element.prototype.scrollIntoView !== "function") {
  Element.prototype.scrollIntoView = () => {};
}
