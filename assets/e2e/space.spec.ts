/**
 * Creating a space: the form, the server, and the page it lands on.
 *
 * A space is the app's unit of work — it carries the workspace, the sandbox and
 * the agents — and the New Space form is the only way to make one. Everything
 * else in the suite starts here.
 */
import { expect, test } from "playwright/test";

import { createSpace, uniqueName } from "./support";

test("the New Space form creates a space that the index then lists", async ({
  page,
}) => {
  const name = uniqueName("space");

  const slug = await createSpace(page, name);

  await test.step("the space's own page is the one it landed on", async () => {
    await expect(page).toHaveURL(new RegExp(`/space/${slug}$`));
    // The feed's heading is the name the server stored, and the blueprint the
    // form sent is stated under it.
    await expect(
      page.getByRole("heading", { level: 1, name, exact: true }),
    ).toBeVisible();
    await expect(page.getByText("Blueprint: Chat")).toBeVisible();
  });

  await test.step("the index lists the space with its root agent", async () => {
    await page.goto("/spaces");

    // Scoped to `main`: the sidebar carries the same link in the drawer, which
    // is off-canvas at this width.
    const card = page.locator("main").getByRole("link", { name });
    await expect(card).toBeVisible();
    await expect(card).toContainText("1 agent");
  });
});
