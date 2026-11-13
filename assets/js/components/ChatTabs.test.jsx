/**
 * ChatTabs component tests.
 *
 * Two shapes, two layouts. `ChatTabs` is the desktop bar: the conversation and
 * the shell jobs, plus the trailing slot the pane's toggle renders into (#169)
 * — it has to be *in the tab bar*, because that bar is the one band the
 * conversation cannot scroll away and it costs no column; a refactor that moves
 * it back beside the conversation is the bug.
 *
 * `PhoneTabs` is the phone's copy, rendered inside the header's disclosure: the
 * same views with the pane's third one, because below `lg` the bar is
 * `max-lg:hidden` and this is the only control there is. The pane's *waiting*
 * signal is not here at all — it is a badge on the header's chevron, since a
 * signal inside a disclosure is one the reader has to open to see.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import {
  ChatTabs,
  CHAT_TAB,
  JOBS_TAB,
  PANE_TAB,
  PhoneTabs,
  tabLabel,
  tabName,
} from "./ChatTabs";

describe("ChatTabs", () => {
  it("renders both tabs, with the job count on the jobs tab", () => {
    render(<ChatTabs active={CHAT_TAB} onSelect={() => {}} jobCount={3} />);

    expect(screen.getByRole("tab", { name: "Chat" })).toBeInTheDocument();
    expect(
      screen.getByRole("tab", { name: "Shell jobs (3)" }),
    ).toBeInTheDocument();
  });

  it("marks the active tab as selected", () => {
    render(<ChatTabs active={JOBS_TAB} onSelect={() => {}} jobCount={1} />);

    expect(screen.getByRole("tab", { name: "Shell jobs (1)" })).toHaveAttribute(
      "aria-selected",
      "true",
    );
    expect(screen.getByRole("tab", { name: "Chat" })).toHaveAttribute(
      "aria-selected",
      "false",
    );
  });

  it("reports the tab the user selected", () => {
    const onSelect = vi.fn();

    render(<ChatTabs active={CHAT_TAB} onSelect={onSelect} jobCount={0} />);

    fireEvent.click(screen.getByRole("tab", { name: "Shell jobs (0)" }));
    expect(onSelect).toHaveBeenCalledWith(JOBS_TAB);
  });

  it("is the desktop's bar, and only the desktop's", () => {
    render(<ChatTabs active={CHAT_TAB} onSelect={() => {}} />);

    // Below `lg` the phone opens the same views from the header's chevron, and
    // this row is what the phone no longer spends on chrome.
    expect(screen.getByRole("tablist").className).toContain("max-lg:hidden");
  });

  it("keeps the pane's toggle out of the phone's tab bar", () => {
    render(
      <ChatTabs
        active={CHAT_TAB}
        onSelect={() => {}}
        trailing={<button type="button">Pane</button>}
      />,
    );

    // Still inside the tab bar (it is the bar's trailing slot), but hidden
    // below `lg`: on a 375px bar the tab above is the control, and two controls
    // for one view would be one too many.
    const slot = screen.getByRole("button", { name: "Pane" }).parentElement;
    expect(screen.getByRole("tablist")).toContainElement(slot);
    expect(slot.className).toContain("hidden");
    expect(slot.className).toContain("lg:block");
  });

  it("renders the trailing slot inside the tab bar", () => {
    render(
      <ChatTabs
        active={CHAT_TAB}
        onSelect={() => {}}
        trailing={<button type="button">Pane</button>}
      />,
    );

    expect(screen.getByRole("tablist")).toContainElement(
      screen.getByRole("button", { name: "Pane" }),
    );
  });
});

describe("PhoneTabs", () => {
  it("offers the same views, with the pane only once a frame has arrived", () => {
    const onSelect = vi.fn();
    const { rerender } = render(
      <PhoneTabs active={CHAT_TAB} onSelect={onSelect} jobCount={2} />,
    );

    // No `pane:state` frame yet: there is nothing to show, so there is no
    // button that opens an empty view — the rule the desktop bar and
    // `PaneToggle` both follow.
    expect(screen.queryByRole("tab", { name: "Pane" })).toBeNull();

    rerender(
      <PhoneTabs active={CHAT_TAB} onSelect={onSelect} jobCount={2} hasPane />,
    );

    const paneTab = screen.getByRole("tab", { name: "Pane" });
    // The waiting count is *not* here: it rides the header's chevron, so a
    // reader sees it without opening this group.
    expect(paneTab.textContent).toBe("Pane");
    expect(screen.queryByTestId("pane-tab-waiting")).toBeNull();
  });

  it("is the phone's copy, marks the active view, and reports a selection", () => {
    const onSelect = vi.fn();
    render(
      <PhoneTabs active={JOBS_TAB} onSelect={onSelect} jobCount={1} hasPane />,
    );

    // `lg:hidden` is the switch: from `lg` up the bar above is the control.
    const group = screen.getByTestId("phone-tabs");
    expect(group.className).toContain("lg:hidden");

    expect(screen.getByRole("tab", { name: "Shell jobs (1)" })).toHaveAttribute(
      "aria-selected",
      "true",
    );
    expect(screen.getByRole("tab", { name: "Chat" })).toHaveAttribute(
      "aria-selected",
      "false",
    );

    fireEvent.click(screen.getByRole("tab", { name: "Pane" }));
    expect(onSelect).toHaveBeenCalledWith(PANE_TAB);
  });

  it("names a view the same way in the bar, the group and the header's chip", () => {
    // One vocabulary for three views: the header's active-view chip, this
    // group and the desktop bar must not drift into three spellings.
    expect(tabName(CHAT_TAB)).toBe("Chat");
    expect(tabName(JOBS_TAB)).toBe("Shell jobs");
    expect(tabName(PANE_TAB)).toBe("Pane");
    expect(tabLabel(JOBS_TAB, 0)).toBe("Shell jobs (0)");
    expect(tabLabel(PANE_TAB, 3)).toBe("Pane");
  });
});
