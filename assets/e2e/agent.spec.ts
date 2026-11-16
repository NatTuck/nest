/**
 * Spawning an agent by hand (#209), and opening the chat it produced.
 *
 * The agent is made through the space page's dialog, which is a space-level
 * action: the new agent is a peer of the root, not a child of anything. The
 * assertions that matter are the ones a browser can only make after the
 * server's reply — the confirmation names the agent the server settled on, and
 * the chat page shows the model the dialog sent.
 */
import { expect, test } from "playwright/test";

import {
  createSpace,
  openAgentFromDrawer,
  phoneHeader,
  spawnAgent,
  uniqueName,
} from "./support";

test("an agent spawned from the space page opens a chat on its chosen model", async ({
  page,
}) => {
  await createSpace(page, uniqueName("spawn-space"));
  const agentName = uniqueName("agent");

  await spawnAgent(page, agentName);

  await test.step("the drawer reaches the new agent's chat", async () => {
    await openAgentFromDrawer(page, agentName);
    // The bar's row is the page's own header on a phone: it is the agent the
    // route names.
    await expect(phoneHeader(page)).toContainText(agentName);
  });

  await test.step("the model the dialog sent is the model the agent runs", async () => {
    await page.getByRole("button", { name: "Agent details" }).click();

    // The chip is the agent's model as the server reports it: provider first,
    // which is what makes it distinguishable from a same-named model elsewhere.
    await expect(page.getByRole("button", { name: "Change model" })).toHaveText(
      "stub: stub-model",
    );
  });
});
