/**
 * Tests for `js/components/ChatHeader.jsx`.
 *
 * Two shapes, and the tests keep them apart by the two `data-testid`s the
 * component puts on them: `phone-header` (the bar's row and its disclosure) and
 * `desktop-header` (the header in the column). Both are in the DOM — which one a
 * reader sees is `lg:hidden` / `hidden lg:block`, decided in the stylesheet — so
 * a test that queried the page globally would be asking about two elements.
 *
 * `TokenUsageChip` is mocked; its behaviour has its own tests.
 */

import { describe, expect, it, vi, beforeEach } from "vitest";
import {
  render,
  screen,
  fireEvent,
  cleanup,
  within,
} from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { ChatHeader } from "./ChatHeader";
import { PhoneBarSlotContext } from "./PhoneBarSlot";

vi.mock("./TokenUsageChip", () => ({
  TokenUsageChip: () => <div data-testid="usage-chip" />,
}));

function header(overrides = {}) {
  const props = {
    name: "alpha",
    vocation: undefined,
    model: undefined,
    agentState: "idle",
    changeModelError: null,
    parentName: null,
    depth: 0,
    spaceSlug: "my-space",
    usage: null,
    descendantUsage: null,
    totalUsage: null,
    contextLimit: null,
    status: "connected",
    streaming: false,
    onModelPickerOpen: vi.fn(),
    getStatusLabel: () => "Idle",
    ...overrides,
  };
  return (
    <MemoryRouter>
      <ChatHeader {...props} />
    </MemoryRouter>
  );
}

const phone = () => within(screen.getByTestId("phone-header"));
const panel = () => within(screen.getByTestId("phone-panel"));
const desktop = () => within(screen.getByTestId("desktop-header"));
const openDetails = () =>
  fireEvent.click(screen.getByRole("button", { name: /^Agent details/ }));

describe("ChatHeader", () => {
  beforeEach(cleanup);

  it("is one row on a phone: the name, the dot and the disclosure", () => {
    render(
      header({
        vocation: { name: "Builder" },
        model: { name: "gpt", provider: "openai" },
      }),
    );

    // The row is a fixed 44px — the height of the control that ends it — and the
    // name truncates rather than wrapping, because a bar that wraps is two rows
    // again.
    const row = screen.getByTestId("phone-header");
    expect(row.className).toContain("h-11");
    expect(row.className).toContain("items-center");

    const heading = phone().getByRole("heading", { name: /alpha/ });
    expect(heading.className).toContain("truncate");
    expect(heading.className).toContain("text-lg");

    // The dot is the one piece of the status row on the line, so it carries the
    // label for a screen reader — a colour alone is not a status.
    expect(phone().getByRole("img", { name: "Idle" })).toBeInTheDocument();

    // Everything else is behind the chevron, and *not rendered* until it opens:
    // a closed bar is one row and nothing hidden is in the tree.
    expect(phone().queryByRole("button", { name: "Change model" })).toBeNull();
    // The panel is not rendered at all, so nothing it holds is in the tree —
    // which is what `max-lg:hidden` used to have to fake. (The desktop header is
    // in the DOM too; that is why the chip assertions are scoped.)
    expect(screen.queryByTestId("phone-panel")).toBeNull();
    expect(
      screen.getByRole("button", { name: "Agent details" }),
    ).toHaveAttribute("aria-expanded", "false");
  });

  it("opens the whole name, the vocation, the model and the status from the chevron", () => {
    const onModelPickerOpen = vi.fn();
    render(
      header({
        name: "charming-rhinoceros-root-the-third",
        vocation: { name: "Builder" },
        model: { name: "gpt", provider: "openai" },
        parentName: "root",
        depth: 2,
        changeModelError: "no such provider",
        onModelPickerOpen,
      }),
    );

    openDetails();

    expect(
      screen.getByRole("button", { name: /^Agent details/ }),
    ).toHaveAttribute("aria-expanded", "true");

    // The row truncates the name; the panel is where it stays readable, with no
    // hover and no `title` — a phone has neither.
    expect(
      panel().getByText("charming-rhinoceros-root-the-third"),
    ).toBeInTheDocument();
    expect(panel().getByText("Builder")).toBeInTheDocument();
    expect(panel().getByTestId("usage-chip")).toBeInTheDocument();
    expect(panel().getByText("Idle")).toBeInTheDocument();

    // The lineage and the change-model error are panel-only below `lg`: the row
    // has no space for either, and the desktop's copy of them is not on screen.
    expect(panel().getByRole("link", { name: /back to root/ })).toHaveAttribute(
      "href",
      "/space/my-space/agent/root",
    );
    expect(panel().getByText("(depth 2)")).toBeInTheDocument();
    expect(panel().getByText("no such provider")).toBeInTheDocument();

    // ...and the model chip still opens the picker from in there.
    fireEvent.click(panel().getByRole("button", { name: "Change model" }));
    expect(onModelPickerOpen).toHaveBeenCalledTimes(1);
  });

  it("puts the waiting questions on the chevron, not behind it", () => {
    render(header({ waitingCount: 2 }));

    // The view switcher is behind this chevron now, so a count on it would be a
    // signal the reader has to open the panel to see. It rides the chevron, and
    // the count is part of the accessible name — not colour-and-digit only.
    const toggle = screen.getByRole("button", {
      name: "Agent details, 2 questions waiting",
    });
    const badge = screen.getByTestId("phone-waiting-badge");
    expect(toggle).toContainElement(badge);
    expect(badge).toHaveTextContent("2");
    expect(badge.querySelector(".bg-amber-500")).not.toBeNull();
  });

  it("says nothing about waiting when nothing is", () => {
    render(header());

    expect(
      screen.getByRole("button", { name: "Agent details" }),
    ).toBeInTheDocument();
    expect(screen.queryByTestId("phone-waiting-badge")).toBeNull();
  });

  it("names the view when it is not the conversation", () => {
    const { rerender } = render(header({ viewName: null, tab: "chat" }));

    // The conversation is the default and needs no label; the other views do,
    // because the phone has no bar and the composer disappears on them.
    expect(screen.queryByTestId("active-view-chip")).toBeNull();

    rerender(header({ viewName: "Shell jobs", tab: "jobs" }));

    const chip = screen.getByTestId("active-view-chip");
    expect(chip).toHaveTextContent("Shell jobs");
    // Inside the bar's row, which is the phone's.
    expect(screen.getByTestId("phone-header")).toContainElement(chip);
  });

  it("renders the phone's view group only while the disclosure is open", () => {
    render(header({ tab: "chat", hasPane: true }));

    expect(screen.queryByTestId("phone-tabs")).toBeNull();

    openDetails();

    expect(screen.getByTestId("phone-tabs")).toBeInTheDocument();
    expect(panel().getByRole("tab", { name: "Pane" })).toBeInTheDocument();
  });

  it("closes the disclosure when a view is picked, and reports it", () => {
    const onSelectTab = vi.fn();
    render(header({ tab: "chat", hasPane: true, onSelectTab }));

    openDetails();
    fireEvent.click(panel().getByRole("tab", { name: "Pane" }));

    expect(onSelectTab).toHaveBeenCalledWith("pane");

    // A menu left open over the view it opened is in the way of that view.
    expect(screen.queryByTestId("phone-tabs")).toBeNull();
    expect(
      screen.getByRole("button", { name: "Agent details" }),
    ).toHaveAttribute("aria-expanded", "false");
  });

  it("portals the phone row into the top bar's slot when there is one", () => {
    const slot = document.createElement("div");
    document.body.appendChild(slot);

    render(
      <MemoryRouter>
        <PhoneBarSlotContext.Provider value={slot}>
          <ChatHeader
            name="alpha"
            status="connected"
            getStatusLabel={() => "Idle"}
          />
        </PhoneBarSlotContext.Provider>
      </MemoryRouter>,
    );

    // In the slot, not in the page's own tree: the bar is above `main`, which is
    // what makes the page spend one row on chrome instead of two.
    expect(slot.querySelector('[data-testid="phone-header"]')).not.toBeNull();
    slot.remove();
  });

  it("renders the desktop header, always expanded", () => {
    render(
      header({
        vocation: { name: "Builder" },
        model: { name: "gpt", provider: "openai" },
        parentName: "root",
        depth: 1,
      }),
    );

    // Nothing is behind a disclosure from `lg` up: the heading carries the
    // vocation inline, and the chip, the usage and the status are all there.
    const heading = desktop().getByRole("heading", { name: /alpha/ });
    expect(heading.className).toContain("text-2xl");
    expect(heading.textContent).toContain("(Builder)");

    expect(
      desktop().getByRole("button", { name: "Change model" }),
    ).toBeInTheDocument();
    expect(screen.getByTestId("usage-chip")).toBeInTheDocument();
    expect(desktop().getByText("Idle")).toBeInTheDocument();
    expect(
      desktop().getByRole("link", { name: /back to root/ }),
    ).toBeInTheDocument();
    expect(desktop().getByText("(depth 1)")).toBeInTheDocument();
    // No disclosure control in the desktop header: everything is already
    // showing there. (The phone's row is in the DOM too, which is why this is
    // scoped.)
    expect(
      desktop().queryByRole("button", { name: /Agent details/ }),
    ).toBeNull();
  });

  it("falls back to '[missing]' and highlights a model_missing agent", () => {
    render(header({ model: undefined, agentState: "model_missing" }));

    const chip = desktop().getByRole("button", { name: "Change model" });
    expect(chip).toHaveTextContent("[missing]");
    expect(chip.className).toContain("bg-amber-100");
  });

  it("renders only the model name when the provider is absent, and the change-model error", () => {
    render(
      header({ model: { name: "gpt" }, changeModelError: "no such provider" }),
    );

    expect(
      desktop().getByRole("button", { name: "Change model" }),
    ).toHaveTextContent("gpt");
    expect(desktop().getByText("no such provider")).toBeInTheDocument();
  });
});
