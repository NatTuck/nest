/**
 * Custom lint: enforce per-file line limits on source files.
 *
 * Two limits (standardized with the Elixir credo check):
 *   - MAX_CODE_LINES (500): "code lines" — every line that is not blank,
 *     not a full-line comment, and not a doc annotation (JSDoc `/** *\/`).
 *     Other multi-line strings (template literals) DO count.
 *   - MAX_TOTAL_LINES (700): every line in the file (blanks, comments,
 *     docs, all).
 *
 * Scope: app source files (`*.js` / `*.jsx` / `*.ts` / `*.tsx`),
 * excluding `*.test.*` / `*.spec.*` files and `__mocks__`.
 *
 * Usage: `node lint-file-size.mjs` — exits 1 if any file exceeds either cap.
 */

import { readdirSync, readFileSync } from "node:fs";
import { join, extname } from "node:path";

const MAX_CODE_LINES = 500;
const MAX_TOTAL_LINES = 700;
const ROOT = "js";

const SOURCE_EXTS = new Set([".js", ".jsx", ".ts", ".tsx"]);
const TEST_RE = /\.(test|spec)\.(jsx?|tsx?)$/;
const MOCK_DIR = "__mocks__";

const offending = [];

function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name !== MOCK_DIR) walk(full);
    } else if (
      entry.isFile() &&
      SOURCE_EXTS.has(extname(entry.name)) &&
      !TEST_RE.test(entry.name)
    ) {
      checkFile(full);
    }
  }
}

// Count "code lines" (non-blank, non-comment, non-doc) and total lines.
// State tracked across lines: `/* ... */` block comments (incl. JSDoc and
// JSX `{/* *\/}`) and backtick template literals. Quotes are tracked per
// line so a `//` inside a string/template isn't mistaken for a comment.
function countLines(content) {
  const lines = content.split("\n");
  let code = 0;
  let inBlockComment = false;
  let inTemplate = false;

  for (const raw of lines) {
    let line = raw;
    let lineCounts = false;

    if (inBlockComment) {
      const close = line.indexOf("*/");
      if (close === -1) continue;
      line = line.slice(close + 2).replace(/^}/, "");
      inBlockComment = false;
    }

    if (inTemplate) {
      const close = line.indexOf("`");
      if (close === -1) {
        code++;
        continue;
      }
      line = line.slice(close + 1);
      inTemplate = false;
      lineCounts = true;
    }

    const hasCode = scanCode(
      line,
      (v) => (inBlockComment = v),
      (v) => (inTemplate = v),
    );
    if (lineCounts || hasCode) code++;
  }

  return { code, total: lines.length };
}

// Scan one line for code, updating block-comment / template state.
function scanCode(line, setBlock, setTemplate) {
  let i = 0;
  let quote = null;
  let code = false;

  while (i < line.length) {
    const ch = line[i];
    const next = line[i + 1];

    if (quote) {
      if (ch === quote && line[i - 1] !== "\\") quote = null;
      i++;
      continue;
    }
    if (ch === "`") {
      setTemplate(true);
      code = true;
      i++;
      continue;
    }
    if (ch === "'" || ch === '"') {
      quote = ch;
      code = true;
      i++;
      continue;
    }
    if (ch === "/" && next === "/") break;
    if (ch === "{" && next === "/" && line[i + 2] === "*") {
      setBlock(true);
      break;
    }
    if (ch === "/" && next === "*") {
      setBlock(true);
      break;
    }
    if (ch !== " " && ch !== "\t" && ch !== "\r") code = true;
    i++;
  }

  return code;
}

function checkFile(path) {
  const { code, total } = countLines(readFileSync(path, "utf8"));
  if (code > MAX_CODE_LINES) {
    offending.push({
      path,
      message: `${code} code lines exceeds the ${MAX_CODE_LINES}-line code cap. Split it into smaller modules.`,
    });
  }
  if (total > MAX_TOTAL_LINES) {
    offending.push({
      path,
      message: `${total} total lines exceeds the ${MAX_TOTAL_LINES}-line total cap. Split it into smaller modules.`,
    });
  }
}

walk(ROOT);

if (offending.length > 0) {
  for (const { path, message } of offending) {
    console.error(`${path}: ${message}`);
  }
  process.exit(1);
}

console.log(
  `OK: no source file exceeds ${MAX_CODE_LINES} code lines or ${MAX_TOTAL_LINES} total lines.`,
);
