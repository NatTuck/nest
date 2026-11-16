/**
 * Sign in once, and keep the browser state for every other spec.
 *
 * This is the suite's only setup step, and the only place the seeded account is
 * used: the app has no registration, so `nat` is the sole way in, and it exists
 * because the seed creates it — the specs do not.
 *
 * What is saved is the token the login reply stored in `localStorage`; every
 * other project starts from it, so no spec repeats the form. The assertion
 * before saving is on the sidebar's **Logout** button, which renders only once
 * the lobby's `init` frame has arrived: a saved state that the server has not
 * accepted would fail every later spec with a redirect to `/login` instead of
 * here, where the reason is obvious.
 */
import { fileURLToPath } from "node:url";
import { expect, test as setup } from "playwright/test";

import { PASSWORD, USERNAME } from "./support";

/** Where the signed-in state lands; `playwright.config.ts` reads the same file. */
const STATE_PATH = fileURLToPath(
  new URL("./.auth/state.json", import.meta.url),
);

setup("sign in as the seeded user", async ({ page }) => {
  await page.goto("/login");

  await page.getByLabel("Username").fill(USERNAME);
  await page.getByLabel("Password").fill(PASSWORD);
  await page.getByRole("button", { name: "Sign in" }).click();

  await expect(page).toHaveURL(/\/spaces$/);
  await expect(page.getByRole("button", { name: "Logout" })).toBeVisible();

  await page.context().storageState({ path: STATE_PATH });
});
