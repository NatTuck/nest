/**
 * ChatTabs component tests.
 *
 * Covers: rendering both tabs (with the job count on the jobs tab),
 * marking the active tab, reporting the selection, and the trailing slot the
 * pane's toggle renders into (#169) — it has to be *in the tab bar*, because
 * that bar is the one band the conversation cannot scroll away and it costs no
 * column; a refactor that moves it back beside the conversation is the bug.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ChatTabs, CHAT_TAB, JOBS_TAB, PANE_TAB } from "./ChatTabs";

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

  it("offers the pane as a third tab only once a frame for the space has arrived", () => {
    const onSelect = vi.fn();
    const { rerender } = render(
      <ChatTabs active={CHAT_TAB} onSelect={onSelect} />,
    );

    // No `pane:state` frame yet: there is nothing to show, so there is no tab
    // that opens an empty view.
    expect(screen.queryByRole("tab", { name: "Pane" })).toBeNull();

    rerender(<ChatTabs active={CHAT_TAB} onSelect={onSelect} hasPane />);

    const paneTab = screen.getByRole("tab", { name: "Pane" });
    // `lg:hidden` is the whole mechanism: below `lg` the tab is the pane's
    // control, and from `lg` up the toggle in the trailing slot is.
    expect(paneTab.className).toContain("lg:hidden");

    fireEvent.click(paneTab);
    expect(onSelect).toHaveBeenCalledWith(PANE_TAB);
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
