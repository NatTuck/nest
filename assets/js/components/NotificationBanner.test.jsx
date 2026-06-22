/**
 * NotificationBanner component tests.
 *
 * Covers: null notification, the rendered message, and the
 * dismiss button callback.
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { NotificationBanner } from "./NotificationBanner";

describe("NotificationBanner", () => {
  it("renders nothing when notification is null", () => {
    const { container } = render(
      <NotificationBanner notification={null} onClose={() => {}} />,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders nothing when notification is undefined", () => {
    const { container } = render(
      <NotificationBanner notification={undefined} onClose={() => {}} />,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders the notification message", () => {
    render(
      <NotificationBanner
        notification={{ message: "Rate limit exceeded" }}
        onClose={() => {}}
      />,
    );

    expect(screen.getByText("Rate limit exceeded")).toBeInTheDocument();
  });

  it("calls onClose when the dismiss button is clicked", () => {
    const onClose = vi.fn();

    render(
      <NotificationBanner notification={{ message: "hi" }} onClose={onClose} />,
    );

    fireEvent.click(screen.getByRole("button", { name: /dismiss/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
