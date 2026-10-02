/**
 * ChatTabs component tests.
 *
 * Covers: rendering both tabs (with the job count on the jobs tab),
 * marking the active tab, and reporting the selection.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { ChatTabs, CHAT_TAB, JOBS_TAB } from "./ChatTabs";

describe("ChatTabs", () => {
  it("renders both tabs, with the job count on the jobs tab", () => {
    render(<ChatTabs active={CHAT_TAB} onSelect={() => {}} jobCount={3} />);

    expect(screen.getByRole("tab", { name: "Chat" })).toBeInTheDocument();
    expect(
      screen.getByRole("tab", { name: "Background jobs (3)" }),
    ).toBeInTheDocument();
  });

  it("marks the active tab as selected", () => {
    render(<ChatTabs active={JOBS_TAB} onSelect={() => {}} jobCount={1} />);

    expect(
      screen.getByRole("tab", { name: "Background jobs (1)" }),
    ).toHaveAttribute("aria-selected", "true");
    expect(screen.getByRole("tab", { name: "Chat" })).toHaveAttribute(
      "aria-selected",
      "false",
    );
  });

  it("reports the tab the user selected", () => {
    const onSelect = vi.fn();

    render(<ChatTabs active={CHAT_TAB} onSelect={onSelect} jobCount={0} />);

    fireEvent.click(screen.getByRole("tab", { name: "Background jobs (0)" }));
    expect(onSelect).toHaveBeenCalledWith(JOBS_TAB);
  });
});
