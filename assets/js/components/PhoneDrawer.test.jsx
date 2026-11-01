/**
 * PhoneDrawer tests: the off-canvas sidebar below `lg`.
 *
 * jsdom has no layout engine and does not evaluate media queries, so nothing
 * here measures a breakpoint. What is pinned is the *behaviour* — open/close,
 * Escape, the backdrop, the scroll lock, and where focus goes — plus the class
 * contract that decides which layout a window gets (`lg:static` on the panel).
 * A `matchMedia` stub would buy nothing: no component reads the viewport width,
 * which is the point of doing this with breakpoints.
 *
 * The drawer is the sidebar at every width — at `lg`+ it is the layout's static
 * first column — so "closed" cannot mean "unmounted". It means off-screen, and
 * `assets/css/app.css` makes that `visibility: hidden` so the links inside are
 * not tabbable while the panel is off the screen.
 */

import { useRef } from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";

import { PhoneDrawer } from "./PhoneDrawer";

// A harness with a real trigger: the focus return is one of the behaviours under
// test, and it is the trigger that has to get focus back.
function Harness({ open, onClose }) {
  const triggerRef = useRef(null);

  return (
    <div>
      <button ref={triggerRef} type="button">
        Hamburger
      </button>
      <PhoneDrawer open={open} onClose={onClose} triggerRef={triggerRef}>
        <a href="/spaces">Spaces</a>
      </PhoneDrawer>
    </div>
  );
}

const panel = () => document.getElementById("phone-navigation");

describe("PhoneDrawer", () => {
  beforeEach(() => {
    document.body.style.overflow = "";
  });

  it("offers no backdrop while it is closed, and a named one while it is open", () => {
    const onClose = vi.fn();
    const { rerender } = render(<Harness open={false} onClose={onClose} />);

    // Nothing to click and nothing to announce: a full-screen button that is
    // still in the tab order would be a trap of its own.
    expect(screen.queryByLabelText("Close navigation")).toBeNull();
    expect(panel()).toHaveAttribute("data-open", "false");

    rerender(<Harness open={true} onClose={onClose} />);

    expect(screen.getByLabelText("Close navigation")).toBeInTheDocument();
    expect(panel()).toHaveAttribute("data-open", "true");

    // The closed panel is off-canvas and `lg:static` is the desktop column: the
    // breakpoint, not a JS viewport check, is what decides which one a window
    // gets.
    expect(panel().className).toContain("lg:static");
  });

  it("closes on the backdrop", () => {
    const onClose = vi.fn();
    render(<Harness open={true} onClose={onClose} />);

    fireEvent.click(screen.getByLabelText("Close navigation"));

    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("closes on Escape, and only while it is open", () => {
    const onClose = vi.fn();
    const { rerender } = render(<Harness open={false} onClose={onClose} />);

    // Closed: the key is somebody else's.
    fireEvent.keyDown(document, { key: "Escape" });
    expect(onClose).not.toHaveBeenCalled();

    rerender(<Harness open={true} onClose={onClose} />);
    fireEvent.keyDown(document, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("locks the page's scroll while it is open and restores what was there", () => {
    const onClose = vi.fn();
    // A value that is not the default: the restore has to put *that* back, not
    // clear the property and lose whatever another surface had set.
    document.body.style.overflow = "scroll";

    const { rerender } = render(<Harness open={true} onClose={onClose} />);
    expect(document.body.style.overflow).toBe("hidden");

    rerender(<Harness open={false} onClose={onClose} />);
    expect(document.body.style.overflow).toBe("scroll");
  });

  it("takes focus into the panel and puts it back on the trigger", () => {
    const onClose = vi.fn();
    const { rerender } = render(<Harness open={true} onClose={onClose} />);

    // Focus left on the hamburger would be focus behind the panel: the reader
    // would tab into the page the backdrop is covering.
    expect(panel()).toHaveFocus();

    rerender(<Harness open={false} onClose={onClose} />);

    // Closing must not strand focus on a control that is now off-screen.
    expect(screen.getByRole("button", { name: "Hamburger" })).toHaveFocus();
  });
});
