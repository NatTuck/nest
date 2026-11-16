/**
 * The phone chat page: one screen, no page scrollbar, and a real round trip.
 *
 * This is the suite's reason for existing. Every claim below is a measurement
 * in a real 390x844 touch browser, because each of them is a layout contract
 * that a unit test with jsdom cannot see: jsdom has no layout, so it cannot
 * report a 44px bar, a 30px composer row, or a scrollbar that should not be
 * there.
 *
 * The page is loaded **cold** (`page.goto`), which is the path that matters
 * most: a client-side navigation has the layout already mounted, while a cold
 * load has to fill the top bar's slot on the first paint. A bookmark or a
 * refresh is exactly this.
 */
import { expect, test } from "playwright/test";

import {
  boxOf,
  conversation,
  createSpace,
  expectNoPageScroll,
  phoneHeader,
  spawnAgent,
  uniqueName,
} from "./support";

const PHONE_WIDTH = 390;
const PHONE_HEIGHT = 844;

/** The height the phone chrome is allowed to cost: one 44px row, nothing more. */
const BAR_ROW = 44;

/**
 * Where the conversation starts: the bar above it, plus `main`'s 12px top
 * padding. The budget of 70 leaves room for the transcript's own inset and
 * nothing for a second chrome row — a header band under the bar would put the
 * conversation at ~100.
 */
const CONVERSATION_TOP_BUDGET = 70;

test("the phone chat page fits one screen and gets an answer", async ({
  page,
}) => {
  const spaceName = uniqueName("phone-space");
  const agentName = uniqueName("phone-agent");

  const slug = await createSpace(page, spaceName);
  await spawnAgent(page, agentName);

  await test.step("the chat page loads cold, with the bar filled in", async () => {
    await page.goto(
      `/space/${encodeURIComponent(slug)}/agent/${encodeURIComponent(agentName)}`,
    );
    await expect(phoneHeader(page)).toContainText(agentName);
  });

  await test.step("the page spends one row on chrome, in the bar", async () => {
    // The header is a portal into the layout's top bar, so it is a child of
    // `header` — above `main` — and not a second band inside the page.
    await expect(
      page.locator("header").getByTestId("phone-header"),
    ).toBeVisible();
    await expect(page.locator("main").getByTestId("phone-header")).toHaveCount(
      0,
    );

    // The bar's own brand is dropped while the slot is filled, by the `:empty`
    // rule in `app.css`. A brand that stayed would be a second name in the row.
    await expect(page.locator(".phone-bar-brand")).toHaveCSS("display", "none");

    const row = await boxOf(phoneHeader(page));
    expect(row.height).toBe(BAR_ROW);
    expect(row.width).toBeLessThanOrEqual(PHONE_WIDTH);
  });

  await test.step("the conversation starts immediately under the bar", async () => {
    // The **transcript**, not its first row: a cold load pins the transcript to
    // the end of the conversation (that is `useScrollToBottom`'s job, and a
    // fresh agent's system row alone is taller than the screen), so the first
    // row's own top is wherever the scroll left it. The distance from the top of
    // the screen to the top of the transcript is the chrome the page spends,
    // which is what this is about.
    const { top } = await conversation(page);
    expect(top).toBeGreaterThanOrEqual(BAR_ROW);
    expect(top).toBeLessThan(CONVERSATION_TOP_BUDGET);
  });

  await test.step("the cold load lands on the latest turn", async () => {
    const { lastBottom, bottom, scrollTop, scrollHeight, clientHeight } =
      await conversation(page);

    // The newest row is on screen — a reader who opens a chat should not have to
    // scroll to find where the conversation is.
    expect(lastBottom).toBeLessThanOrEqual(bottom + 1);

    // ...and when the conversation is longer than the box, the box is showing
    // its end rather than its start.
    if (scrollHeight > clientHeight) {
      expect(scrollHeight - clientHeight - scrollTop).toBeLessThanOrEqual(1);
    }
  });

  await test.step("nothing scrolls the page", async () => {
    await expectNoPageScroll(page);

    // The phone viewport is the one the assertions above were measured in, and
    // the chat page is the height the viewport gives it — no more.
    expect(page.viewportSize()).toEqual({
      width: PHONE_WIDTH,
      height: PHONE_HEIGHT,
    });
  });

  await test.step("the composer's controls are one 30px row", async () => {
    // The mode group and Send are deliberately smaller than a thumb target on a
    // phone (`max-lg:py-0.5` / `max-lg:py-1`): they share the composer's second
    // line with the field, and 30px is what the two of them plus their borders
    // come to. The stylesheet's comments name the number; this is the check.
    const send = await boxOf(
      page.getByRole("button", { name: "Send", exact: true }),
    );
    const modeGroup = await boxOf(
      page.locator('fieldset[aria-label="Agent mode"]'),
    );

    expect(send.height).toBe(30);
    expect(modeGroup.height).toBe(30);
  });

  await test.step("opening the details panel does not move the page", async () => {
    const before = await boxOf(phoneHeader(page));

    await page.getByRole("button", { name: "Agent details" }).click();
    await expect(page.getByTestId("phone-panel")).toBeVisible();

    // The panel is the bar's own content: it grows the bar downward, and the
    // page behind it neither scrolls nor shifts.
    await expectNoPageScroll(page);
    const after = await boxOf(phoneHeader(page));
    expect(after.y).toBe(before.y);
    expect(after.height).toBe(before.height);

    await page.getByRole("button", { name: "Agent details" }).click();
    await expect(page.getByTestId("phone-panel")).toHaveCount(0);
  });

  await test.step("a message goes out and the provider's answer comes back", async () => {
    // `textbox`, not `getByLabel`: "Copy message" is an `aria-label` that
    // contains "Message", and `getByLabel` matches on a substring.
    await page.getByRole("textbox", { name: "Message" }).fill("ping");
    await page.getByRole("button", { name: "Send", exact: true }).click();

    // The stub provider (`scripts/e2e/stub-llm.mjs`) answers every turn with
    // this sentence, so it is the proof the whole chain ran: composer, socket,
    // agent, provider, stream, transcript.
    await expect(page.getByText("pong from the stub")).toBeVisible();

    // The user's own turn is in the transcript too, and the page is still one
    // screen high — a long answer is the transcript's to scroll, not the page's.
    await expect(page.getByText("ping", { exact: true })).toBeVisible();
    await expectNoPageScroll(page);
  });
});
