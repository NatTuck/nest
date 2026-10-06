/**
 * useScrollToBottom hook tests
 *
 * Covers the scroll/auto-scroll behavior driven by the hook:
 * - At-bottom detection: a `scroll` event re-pins at the bottom and
 *   un-pins when it moved upward (scrollbar drag); a real user gesture
 *   (wheel-up, touchmove, PageUp/ArrowUp/Home) un-pins immediately.
 *   ArrowUp/Home are ignored while an editable field has focus or a
 *   modifier is held; PageUp always counts.
 * - Auto-scroll when at the bottom
 * - hasNewContent flips to true when scrolled up and a new trigger arrives
 * - hasNewContent clears when the user scrolls back to the bottom
 * - jumpToBottom smooth-scrolls and clears the flag
 * - Changing the id resets the hook state and scrolls to the bottom
 */

import { describe, it, beforeEach, vi, expect } from "vitest";
import { renderHook, act, fireEvent } from "@testing-library/react";
import { useScrollToBottom } from "./useScrollToBottom";

const SCROLL_INTO_VIEW_INSTALLED = Symbol.for("scroll-into-view-installed");

beforeEach(() => {
  if (!Element.prototype[SCROLL_INTO_VIEW_INSTALLED]) {
    Element.prototype.scrollIntoView = () => {};
    Object.defineProperty(Element.prototype, SCROLL_INTO_VIEW_INSTALLED, {
      value: true,
    });
  }
});

// Default metrics start at the bottom (scrollTop === scrollHeight - clientHeight,
// i.e. distanceFromBottom === 0) because the hook un-pins on scroll direction: a
// scroll-up only registers if scrollTop decreases from where it was. Starting at
// the bottom makes a later setMetrics({ scrollTop: ... }) a genuine move away from
// (or back to) the bottom.
function setupContainer({
  scrollTop = 500,
  scrollHeight = 1000,
  clientHeight = 500,
} = {}) {
  const el = document.createElement("div");
  Object.defineProperty(el, "scrollTop", {
    value: scrollTop,
    configurable: true,
    writable: true,
  });
  Object.defineProperty(el, "scrollHeight", {
    value: scrollHeight,
    configurable: true,
  });
  Object.defineProperty(el, "clientHeight", {
    value: clientHeight,
    configurable: true,
  });
  document.body.appendChild(el);
  return el;
}

function setMetrics(el, { scrollTop, scrollHeight, clientHeight }) {
  if (scrollTop !== undefined) {
    Object.defineProperty(el, "scrollTop", {
      value: scrollTop,
      configurable: true,
      writable: true,
    });
  }
  if (scrollHeight !== undefined) {
    Object.defineProperty(el, "scrollHeight", {
      value: scrollHeight,
      configurable: true,
    });
  }
  if (clientHeight !== undefined) {
    Object.defineProperty(el, "clientHeight", {
      value: clientHeight,
      configurable: true,
    });
  }
}

/** Simulate the user scrolling the container back to the bottom. */
function scrollToBottom(container) {
  setMetrics(container, {
    scrollTop: 500,
    scrollHeight: 1000,
    clientHeight: 500,
  });
  act(() => {
    fireEvent.scroll(container);
  });
}

/**
 * Renders the hook with a container element pre-attached so the
 * scroll listener can find it on first render.
 */
function renderHookWithContainer(initialId, initialTrigger) {
  const container = setupContainer();
  const messagesEnd = document.createElement("div");
  container.appendChild(messagesEnd);

  const result = renderHook(
    ({ id, trigger }) => useScrollToBottom(container, messagesEnd, id, trigger),
    { initialProps: { id: initialId, trigger: initialTrigger } },
  );
  return { ...result, container, messagesEnd };
}

describe("useScrollToBottom", () => {
  describe("at-bottom detection", () => {
    it("starts with isAtBottom = true and hasNewContent = false", () => {
      const { result } = renderHookWithContainer("agent-1", null);
      expect(result.current.isAtBottom).toBe(true);
      expect(result.current.hasNewContent).toBe(false);
    });

    it("un-pins when the user wheels up", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);
      act(() => {
        fireEvent.wheel(container, { deltaY: -100 });
      });
      expect(result.current.isAtBottom).toBe(false);
    });

    it("does not re-pin on a wheel-down", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);
      act(() => {
        fireEvent.wheel(container, { deltaY: -100 });
      });
      expect(result.current.isAtBottom).toBe(false);

      act(() => {
        fireEvent.wheel(container, { deltaY: 100 });
      });
      expect(result.current.isAtBottom).toBe(false);
    });

    it("un-pins when the user drags the container (touchmove)", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);
      act(() => {
        fireEvent.touchMove(container);
      });
      expect(result.current.isAtBottom).toBe(false);
    });

    it("un-pins on PageUp/ArrowUp/Home keydown on window", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);

      for (const key of ["PageUp", "ArrowUp", "Home"]) {
        act(() => {
          fireEvent.keyDown(window, { key });
        });
        expect(result.current.isAtBottom).toBe(false);

        // Re-pin before exercising the next key.
        scrollToBottom(container);
        expect(result.current.isAtBottom).toBe(true);
      }
    });

    it("stays pinned on an unrelated keydown", () => {
      const { result } = renderHookWithContainer("agent-1", null);
      act(() => {
        fireEvent.keyDown(window, { key: "a" });
      });
      expect(result.current.isAtBottom).toBe(true);
    });

    it("un-pins on PageUp even when the composer textarea has focus", () => {
      // PageUp is a scroll command: the browser routes it to the scroll
      // container, not the textarea, and focus normally sits in the
      // composer while streaming -- so the guard must not swallow it.
      const { result } = renderHookWithContainer("agent-1", null);
      const textarea = document.createElement("textarea");
      document.body.appendChild(textarea);

      act(() => {
        fireEvent.keyDown(textarea, { key: "PageUp" });
      });
      expect(result.current.isAtBottom).toBe(false);
    });

    it("does not un-pin on ArrowUp/Home while an editable field has focus", () => {
      // In a text field these move the caret (or, with Ctrl/Cmd, walk the
      // composer's history), so they are not scroll-up intent.
      const { result } = renderHookWithContainer("agent-1", null);
      const wrapper = document.createElement("div");
      const input = document.createElement("input");
      wrapper.appendChild(input);
      const textarea = document.createElement("textarea");
      const editable = document.createElement("div");
      editable.setAttribute("contenteditable", "true");
      const select = document.createElement("select");
      document.body.append(wrapper, textarea, editable, select);

      for (const target of [input, textarea, editable, select]) {
        for (const key of ["ArrowUp", "Home"]) {
          act(() => {
            fireEvent.keyDown(target, { key });
          });
          expect(result.current.isAtBottom).toBe(true);
        }
      }
    });

    it("un-pins on ArrowUp/Home when focus is on the page body", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);

      for (const key of ["ArrowUp", "Home"]) {
        act(() => {
          fireEvent.keyDown(document.body, { key });
        });
        expect(result.current.isAtBottom).toBe(false);

        // Re-pin before exercising the next key.
        scrollToBottom(container);
        expect(result.current.isAtBottom).toBe(true);
      }
    });

    it("does not un-pin on Ctrl/Cmd/Alt + ArrowUp", () => {
      const { result } = renderHookWithContainer("agent-1", null);

      for (const modifier of ["ctrlKey", "metaKey", "altKey"]) {
        act(() => {
          fireEvent.keyDown(document.body, {
            key: "ArrowUp",
            [modifier]: true,
          });
        });
        expect(result.current.isAtBottom).toBe(true);
      }
    });

    it("does not un-pin on a scroll event caused by content growth (scrollTop unchanged, scrollHeight grew)", () => {
      // Content growth changes scrollHeight only, so scrollTop does not
      // decrease and the direction check must leave the view pinned. (The
      // auto-scroll suite covers the follow-on effect; here we pin the
      // scroll-handler rule itself.)
      const { result, container } = renderHookWithContainer("agent-1", null);
      setMetrics(container, {
        scrollTop: 500,
        scrollHeight: 1200,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });
      expect(result.current.isAtBottom).toBe(true);
      expect(result.current.hasNewContent).toBe(false);
    });

    it("un-pins when a scroll event moves the scroll position upward (scrollbar drag)", () => {
      // Dragging the scrollbar, Space and Shift+Space produce only `scroll`
      // events -- no wheel/touch/key event ever reaches us -- so the
      // direction check is the only thing that can stop auto-scroll there.
      const { result, container } = renderHookWithContainer("agent-1", null);
      setMetrics(container, { scrollTop: 200 });
      act(() => {
        fireEvent.scroll(container);
      });
      expect(result.current.isAtBottom).toBe(false);

      // Dragging back down part-way (still away from the bottom) is not a
      // re-pin either; only reaching the bottom is.
      setMetrics(container, { scrollTop: 400 });
      act(() => {
        fireEvent.scroll(container);
      });
      expect(result.current.isAtBottom).toBe(false);
    });

    it("flips isAtBottom back to true when the user scrolls back to the bottom", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);
      act(() => {
        fireEvent.wheel(container, { deltaY: -100 });
      });
      expect(result.current.isAtBottom).toBe(false);

      scrollToBottom(container);
      expect(result.current.isAtBottom).toBe(true);
    });
  });

  describe("auto-scroll on new content", () => {
    it("scrolls to the bottom when at-bottom and a new trigger arrives", () => {
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;

      try {
        const { rerender } = renderHookWithContainer("agent-1", "token-1");
        scrollIntoView.mockClear();
        rerender({ id: "agent-1", trigger: "token-2" });
        expect(scrollIntoView).toHaveBeenCalled();
      } finally {
        Element.prototype.scrollIntoView = original;
      }
    });

    it("does not scroll when scrolled up and a new trigger arrives", () => {
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;

      try {
        const { result, container, rerender } = renderHookWithContainer(
          "agent-1",
          "token-1",
        );
        act(() => {
          fireEvent.wheel(container, { deltaY: -100 });
        });
        scrollIntoView.mockClear();

        rerender({ id: "agent-1", trigger: "token-2" });

        expect(scrollIntoView).not.toHaveBeenCalled();
        expect(result.current.hasNewContent).toBe(true);
      } finally {
        Element.prototype.scrollIntoView = original;
      }
    });

    it("clears hasNewContent when the user scrolls back to the bottom", () => {
      const { result, container } = renderHookWithContainer(
        "agent-1",
        "token-1",
      );

      act(() => {
        fireEvent.wheel(container, { deltaY: -100 });
      });
      // Un-pinning re-runs the auto-scroll effect, which raises the flag.
      expect(result.current.hasNewContent).toBe(true);

      scrollToBottom(container);
      expect(result.current.hasNewContent).toBe(false);
    });

    it("un-pins auto-scroll after a small scroll-up", () => {
      // Regression for issue #6: a wheel-up of only a few pixels used to
      // stay "at bottom" under a 300px slop, so the next streamed token
      // yanked the view back down. Any user scroll-up must un-pin.
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;

      try {
        const { result, container, rerender } = renderHookWithContainer(
          "agent-1",
          "token-1",
        );
        setMetrics(container, { scrollTop: 480 });
        act(() => {
          fireEvent.wheel(container, { deltaY: -20 });
        });
        expect(result.current.isAtBottom).toBe(false);
        // Un-pinning re-runs the auto-scroll effect, so hasNewContent is
        // already true here -- assert it now, not after the trigger.
        expect(result.current.hasNewContent).toBe(true);

        scrollIntoView.mockClear();
        rerender({ id: "agent-1", trigger: "token-2" });

        expect(scrollIntoView).not.toHaveBeenCalled();
      } finally {
        Element.prototype.scrollIntoView = original;
      }
    });

    it("stays pinned when content grows while at the bottom", () => {
      // Streaming grows scrollHeight without moving scrollTop; that is not a
      // user scroll-up, so the hook must keep auto-scrolling the new content.
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;

      try {
        const { result, container, rerender } = renderHookWithContainer(
          "agent-1",
          "token-1",
        );
        setMetrics(container, { scrollHeight: 1200 });
        act(() => {
          fireEvent.scroll(container);
        });
        expect(result.current.isAtBottom).toBe(true);

        scrollIntoView.mockClear();
        rerender({ id: "agent-1", trigger: "token-2" });

        expect(scrollIntoView).toHaveBeenCalled();
      } finally {
        Element.prototype.scrollIntoView = original;
      }
    });
  });

  describe("jumpToBottom", () => {
    it("smooth-scrolls to the bottom and clears hasNewContent", () => {
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;

      try {
        const { result, container } = renderHookWithContainer(
          "agent-1",
          "token-1",
        );
        act(() => {
          fireEvent.wheel(container, { deltaY: -100 });
        });
        expect(result.current.hasNewContent).toBe(true);

        scrollIntoView.mockClear();
        act(() => {
          result.current.jumpToBottom();
        });

        expect(scrollIntoView).toHaveBeenCalledWith(
          expect.objectContaining({ behavior: "smooth" }),
        );
        expect(result.current.hasNewContent).toBe(false);
      } finally {
        Element.prototype.scrollIntoView = original;
      }
    });
  });

  describe("id change resets state", () => {
    it("resets to at-bottom with no pending content when id changes", () => {
      const { result, container, rerender } = renderHookWithContainer(
        "agent-1",
        "token-1",
      );
      act(() => {
        fireEvent.wheel(container, { deltaY: -100 });
      });
      expect(result.current.hasNewContent).toBe(true);

      rerender({ id: "agent-2", trigger: "token-1" });
      expect(result.current.isAtBottom).toBe(true);
      expect(result.current.hasNewContent).toBe(false);
    });
  });

  describe("ref handling", () => {
    it("does not throw when the scroll container el is null on mount", () => {
      expect(() => {
        renderHook(() => useScrollToBottom(null, null, "agent-1", "trigger"));
      }).not.toThrow();
    });

    it("attaches the listeners when the container el appears after mount", () => {
      // Simulates the page initially rendering a loading state (no scroll
      // container in the DOM), then later rendering the messages view. The
      // hook must re-attach the scroll listener when the element appears;
      // otherwise isAtBottom would stay at the default true forever and the
      // page would jump to the bottom on every new message.
      const container = setupContainer();
      const messagesEnd = document.createElement("div");
      container.appendChild(messagesEnd);

      const { result, rerender } = renderHook(
        ({ containerEl, endEl }) =>
          useScrollToBottom(containerEl, endEl, "agent-1", "token-1"),
        { initialProps: { containerEl: null, endEl: null } },
      );

      // Element appears (cache populates, messages view renders)
      rerender({ containerEl: container, endEl: messagesEnd });

      // User wheels up -- this should update isAtBottom to false
      act(() => {
        fireEvent.wheel(container, { deltaY: -100 });
      });

      expect(result.current.isAtBottom).toBe(false);
    });

    it("auto-scrolls the new element when the container el appears after mount", () => {
      // When the scroll container appears late (e.g. after a loading state),
      // a fresh trigger should not cause a jump if the user is not at the
      // bottom -- the listener is attached and isAtBottom is correctly false.
      const container = setupContainer();
      const messagesEnd = document.createElement("div");
      container.appendChild(messagesEnd);

      const { result, rerender } = renderHook(
        ({ containerEl, endEl, trigger }) =>
          useScrollToBottom(containerEl, endEl, "agent-1", trigger),
        {
          initialProps: {
            containerEl: null,
            endEl: null,
            trigger: "token-1",
          },
        },
      );

      // Element appears
      rerender({
        containerEl: container,
        endEl: messagesEnd,
        trigger: "token-1",
      });

      // User wheels up
      act(() => {
        fireEvent.wheel(container, { deltaY: -100 });
      });
      expect(result.current.isAtBottom).toBe(false);

      // A new trigger arrives while scrolled up -- the hook should NOT scroll
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;
      try {
        rerender({
          containerEl: container,
          endEl: messagesEnd,
          trigger: "token-2",
        });
        expect(scrollIntoView).not.toHaveBeenCalled();
        expect(result.current.hasNewContent).toBe(true);
      } finally {
        Element.prototype.scrollIntoView = original;
      }
    });
  });
});
