/**
 * The flows every spec needs, written once.
 *
 * Everything here is a **user action**: the specs drive the same form a person
 * would. Nothing is seeded and nothing is written to the database directly —
 * the space, the agent and the conversation are all created through the UI,
 * which is the whole point of running a browser.
 *
 * The two exceptions are the ones a person cannot supply from a browser and
 * that the app refuses to invent:
 *
 *   * the **account** — the app has no registration, so the seeded user is the
 *     only way in (`auth.setup.ts`);
 *   * the **workspace directory** — the New Space form asks for a path that must
 *     already be a directory, and a browser cannot make one. It is created empty
 *     under the repo's gitignored `tmp/`, which is a filesystem precondition
 *     rather than application state.
 */
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, type Locator, type Page } from "playwright/test";

/** The seeded user (`priv/repo/seeds.exs`). There is no registration. */
export const USERNAME = "nat";
export const PASSWORD = "bacon4242";

/** The model the e2e provider offers (`scripts/e2e/config.toml`). */
export const MODEL = "stub-model";

/**
 * A name no earlier run has used.
 *
 * The database is *not* reset between runs — a second run has to pass on the
 * data the first one left behind — so a fixed name would collide with the space
 * the previous run created. The counter keeps two names in one run distinct
 * even if they are made in the same millisecond.
 */
let counter = 0;
export function uniqueName(purpose: string): string {
  counter += 1;
  return `${purpose}-${Date.now().toString(36)}-${counter}`;
}

/**
 * The space's workspace directory: created empty, under the repo's gitignored
 * `tmp/`, and never reused.
 *
 * It has to be a real directory that already exists (the form refuses a path
 * that is not one) and it must not be under `/tmp`, which is where the sandbox
 * binds an agent's scratch (`Nest.Sandbox.workspace_error/1` refuses it).
 */
export function workspaceDir(name: string): string {
  const dir = fileURLToPath(new URL(`../../tmp/e2e/${name}`, import.meta.url));
  mkdirSync(dir, { recursive: true });
  return dir;
}

/**
 * A locator's box, or a failure naming the element.
 *
 * `boundingBox()` is `null` for an element that is not rendered, and every
 * measurement in this suite is meaningless in that case: the point is to say
 * so, not to read `null.height` and report a TypeError.
 */
export async function boxOf(locator: Locator) {
  const box = await locator.boundingBox();
  if (box === null) {
    throw new Error(`${locator} is not rendered, so it has no box to measure`);
  }
  return box;
}

/**
 * Fill the New Space form and land on the new space's page.
 *
 * Returns the space's slug, which is derived from the name on the server. The
 * blueprint is `Chat`: one conversational agent with no tools, which is all the
 * suite needs and the least that can go wrong on a runner.
 */
export async function createSpace(page: Page, name: string): Promise<string> {
  await page.goto("/spaces/new");

  // The blueprint and model lists come from the lobby's `init` frame, so they
  // are empty for the first render of a cold load. Waiting for the option is
  // waiting for that frame — not a clock.
  await expect(
    page.getByLabel("Select Blueprint").locator("option", { hasText: "Chat" }),
  ).toHaveCount(1);

  await page.getByLabel("Space Name").fill(name);
  await page.getByLabel("Select Blueprint").selectOption({ label: "Chat" });
  await page.getByLabel("Select Model").selectOption(MODEL);
  await page.getByLabel("Workspace Path").fill(workspaceDir(name));
  await page.getByRole("button", { name: "Create Space" }).click();

  // The page navigates on the server's reply, so the heading is the space the
  // server actually created. `level: 1` and `exact`: the environment card's own
  // heading carries the workspace path, which contains this name.
  await expect(
    page.getByRole("heading", { level: 1, name, exact: true }),
  ).toBeVisible();

  const path = new URL(page.url()).pathname;
  const slug = decodeURIComponent(path.slice(path.lastIndexOf("/") + 1));
  expect(slug).not.toBe("");
  return slug;
}

/**
 * Spawn a top-level agent through the space page's `+ Agent` dialog, and wait
 * for the confirmation the server's reply produces.
 *
 * The name is given rather than generated so the spec knows the URL to open.
 */
export async function spawnAgent(page: Page, name: string): Promise<void> {
  await page.getByRole("button", { name: "+ Agent" }).click();
  const dialog = page.getByRole("dialog", { name: "Spawn agent" });
  await expect(dialog).toBeVisible();

  await expect(
    dialog.getByLabel("Model").locator("option", { hasText: MODEL }),
  ).toHaveCount(1);

  await dialog.getByLabel("Name").fill(name);
  await dialog.getByLabel("Model").selectOption(MODEL);
  await dialog.getByRole("button", { name: "Spawn", exact: true }).click();

  await expect(page.getByText(`Spawned ${name}.`)).toBeVisible();
}

/**
 * Walk to an agent's chat the way a phone does: open the drawer, follow the
 * agent's row.
 */
export async function openAgentFromDrawer(
  page: Page,
  name: string,
): Promise<void> {
  await page.getByRole("button", { name: "Open navigation" }).click();
  await page.getByRole("link", { name }).click();
  await expect(page).toHaveURL(new RegExp(`/agent/${name}$`));
}

/** The chat page's own bar row, portalled into the layout's top bar. */
export function phoneHeader(page: Page) {
  return page.getByTestId("phone-header");
}

/**
 * The conversation's own scroller, measured.
 *
 * The rows' nearest scrollable ancestor is the transcript (`ChatMessages`'
 * `overflow-y-auto` box). It is found by walking up from a row rather than by a
 * test id, because what the measurement is about is the *scrolling* element: the
 * chrome above the conversation is exactly the distance from the top of the
 * screen to the top of this box, whatever the markup in between.
 *
 * `lastBottom` is the newest row's bottom edge, in viewport coordinates.
 */
export async function conversation(page: Page) {
  return page.evaluate(() => {
    const rows = [...document.querySelectorAll('[data-testid="message"]')];
    const first = rows[0];
    const last = rows[rows.length - 1];
    if (first === undefined || last === undefined) {
      throw new Error("the conversation has no rows to measure");
    }

    let scroller: HTMLElement | null = first.parentElement;
    while (scroller !== null) {
      const { overflowY } = getComputedStyle(scroller);
      if (overflowY === "auto" || overflowY === "scroll") break;
      scroller = scroller.parentElement;
    }
    if (scroller === null) {
      throw new Error("no scroll container above the conversation's rows");
    }

    const box = scroller.getBoundingClientRect();
    return {
      top: box.top,
      bottom: box.bottom,
      lastBottom: last.getBoundingClientRect().bottom,
      scrollTop: scroller.scrollTop,
      scrollHeight: scroller.scrollHeight,
      clientHeight: scroller.clientHeight,
    };
  });
}

/**
 * Neither the document nor `main` may scroll on the chat page: the shell is
 * exactly one viewport, and a page-level scrollbar on a phone is the defect the
 * `overflow-hidden` chat route exists to prevent. A hidden scrollbar still
 * counts — this measures the geometry, not the gutter, and reports how many
 * pixels overflow.
 */
export async function expectNoPageScroll(page: Page): Promise<void> {
  const overflow = await page.evaluate(() => {
    const doc = document.scrollingElement;
    const main = document.querySelector("main");
    if (doc === null || main === null) {
      throw new Error("the app shell (html/main) is not rendered");
    }
    return {
      documentOverflow: doc.scrollHeight - doc.clientHeight,
      mainOverflow: main.scrollHeight - main.clientHeight,
      scrollY: window.scrollY,
    };
  });

  expect(overflow).toEqual({
    documentOverflow: 0,
    mainOverflow: 0,
    scrollY: 0,
  });
}
