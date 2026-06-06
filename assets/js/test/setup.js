import { expect } from "vitest";
import * as matchers from "@testing-library/jest-dom/matchers";

// Add jest-dom matchers to Vitest
expect.extend(matchers);

// Ensure jsdom globals are available
if (typeof document === "undefined") {
  throw new Error("jsdom environment not loaded. Check vitest config.");
}
