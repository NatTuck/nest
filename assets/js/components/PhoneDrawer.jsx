/**
 * The phone's navigation drawer: the sidebar, off-canvas below `lg`.
 *
 * `Layout` owns the open state and passes it in — the hamburger in
 * `PhoneTopBar` is the other half of this control — and this module owns the
 * four things that make an off-canvas panel behave like one:
 *
 *   * **Escape closes it**, the way it closes every other dismissible surface.
 *   * **The backdrop closes it**, and it is a real button (not a decorated
 *     `div`) with an accessible name, so it is reachable and announced rather
 *     than being a mouse-only target.
 *   * **The page behind does not scroll** while the panel covers it, and it is
 *     put back to whatever it was, not to `""` — another surface may have set it.
 *   * **Focus goes in and comes back**: into the panel when it opens, and back
 *     onto the hamburger when it closes, so closing never leaves focus on a
 *     control the reader cannot see.
 *
 * The closed panel is still in the DOM — it is the sidebar, and at `lg` it is
 * the layout's first column — so being off-screen is not enough to make it
 * inert: `assets/css/app.css`'s `.phone-drawer` rule makes it
 * `visibility: hidden` while closed, which is what takes it out of the tab order
 * and the accessibility tree, and it applies only below `lg`.
 *
 * `Layout` also marks the page behind `inert` while the panel is open, so a Tab
 * cannot walk out of the drawer into content the backdrop is covering.
 *
 * Deliberately **not** `role="dialog"`: the same element is the desktop's static
 * sidebar at `lg`, where it is not a dialog at all, and there is no way to
 * change a role at a breakpoint. The hamburger's `aria-expanded` +
 * `aria-controls` is the disclosure pattern, which is what this control actually
 * is.
 *
 * Nor is it a `matchMedia` component: which layout a window gets is decided by
 * Tailwind's breakpoints alone, so nothing here reads the viewport width.
 */

import { useEffect, useRef } from "react";

export function PhoneDrawer({ open, onClose, triggerRef, children }) {
  const panelRef = useRef(null);

  // Escape, while the drawer is open and only then.
  useEffect(() => {
    if (!open) return;

    const handleKeyDown = (event) => {
      if (event.key === "Escape") onClose();
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [open, onClose]);

  // The page behind does not scroll under the drawer.
  useEffect(() => {
    if (!open) return;

    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = previous;
    };
  }, [open]);

  // Focus in on open, and back onto the hamburger on close.
  useEffect(() => {
    if (!open) return;

    panelRef.current?.focus();
    return () => triggerRef?.current?.focus();
  }, [open, triggerRef]);

  return (
    <>
      {/* Above the page, below the panel. Rendered only while open: an invisible
          full-screen button that is still in the tab order is a worse trap than
          no backdrop at all. */}
      {open && (
        <button
          type="button"
          aria-label="Close navigation"
          onClick={onClose}
          className="fixed inset-0 z-30 bg-gray-900/40 lg:hidden"
        />
      )}

      <div
        ref={panelRef}
        id="phone-navigation"
        tabIndex={-1}
        data-open={open ? "true" : "false"}
        className={[
          // Off-canvas below `lg`; the layout's static first column at `lg`+.
          // A row flex, so the sidebar inside stretches to the panel's full
          // height exactly as it stretches in the desktop row.
          "phone-drawer fixed inset-y-0 left-0 z-40 flex w-64 max-w-[85vw] bg-white shadow-xl",
          "lg:static lg:z-auto lg:w-64 lg:max-w-none lg:translate-x-0 lg:shadow-none",
          // The notch and the home indicator are the panel's own edges on a
          // phone; at `lg` both insets are 0.
          "pt-[env(safe-area-inset-top)] pb-[env(safe-area-inset-bottom)]",
          open ? "translate-x-0" : "-translate-x-full",
        ].join(" ")}
      >
        {children}
      </div>
    </>
  );
}

export default PhoneDrawer;
