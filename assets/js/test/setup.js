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
// stub, but note what it does and does not cover: `ChatPage.test.jsx` and
// `SpaceFeed.test.jsx` mock the hook, and `useScrollToBottom.test.js` installs
// its own stub — so the only test that renders the *real* hook is
// `App.test.jsx`, and this is what keeps it from throwing. The cost is that
// that one test can no longer observe a scroll.
if (typeof Element.prototype.scrollIntoView !== "function") {
  Element.prototype.scrollIntoView = () => {};
}
