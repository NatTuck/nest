/**
 * useScrollToBottom hook tests
 *
 * Covers the scroll/auto-scroll behavior driven by the hook:
 * - At-bottom detection via the scroll listener
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

function setupContainer({
  scrollTop = 0,
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

    it("treats being within 300px of the bottom as at-bottom", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);
      setMetrics(container, {
        scrollTop: 250,
        scrollHeight: 1000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });
      expect(result.current.isAtBottom).toBe(true);
    });

    it("flips isAtBottom to false when the user scrolls up past the threshold", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);
      setMetrics(container, {
        scrollTop: 0,
        scrollHeight: 1000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });
      expect(result.current.isAtBottom).toBe(false);
    });

    it("flips isAtBottom back to true when the user scrolls back to the bottom", () => {
      const { result, container } = renderHookWithContainer("agent-1", null);
      setMetrics(container, {
        scrollTop: 0,
        scrollHeight: 1000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });
      expect(result.current.isAtBottom).toBe(false);

      setMetrics(container, {
        scrollTop: 500,
        scrollHeight: 1000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });
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

    it("does not scroll when scrolled up and a new trigger arrives, but flips hasNewContent", () => {
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;

      try {
        const { result, container, rerender } = renderHookWithContainer(
          "agent-1",
          "token-1",
        );
        setMetrics(container, {
          scrollTop: 0,
          scrollHeight: 1000,
          clientHeight: 500,
        });
        act(() => {
          fireEvent.scroll(container);
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
      const { result, container, rerender } = renderHookWithContainer(
        "agent-1",
        "token-1",
      );
      setMetrics(container, {
        scrollTop: 0,
        scrollHeight: 1000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });

      rerender({ id: "agent-1", trigger: "token-2" });
      expect(result.current.hasNewContent).toBe(true);

      setMetrics(container, {
        scrollTop: 500,
        scrollHeight: 1000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });
      expect(result.current.hasNewContent).toBe(false);
    });
  });

  describe("jumpToBottom", () => {
    it("smooth-scrolls to the bottom and clears hasNewContent", () => {
      const scrollIntoView = vi.fn();
      const original = Element.prototype.scrollIntoView;
      Element.prototype.scrollIntoView = scrollIntoView;

      try {
        const { result, container, rerender } = renderHookWithContainer(
          "agent-1",
          "token-1",
        );
        setMetrics(container, {
          scrollTop: 0,
          scrollHeight: 1000,
          clientHeight: 500,
        });
        act(() => {
          fireEvent.scroll(container);
        });
        rerender({ id: "agent-1", trigger: "token-2" });
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
      setMetrics(container, {
        scrollTop: 0,
        scrollHeight: 1000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
      });
      rerender({ id: "agent-1", trigger: "token-2" });
      expect(result.current.hasNewContent).toBe(true);

      rerender({ id: "agent-2", trigger: "token-2" });
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

    it("attaches the scroll listener when the container el appears after mount", () => {
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

      // User scrolls up -- this should update isAtBottom to false
      setMetrics(container, {
        scrollTop: 0,
        scrollHeight: 2000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
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

      // User scrolls up; trigger a scroll event
      setMetrics(container, {
        scrollTop: 0,
        scrollHeight: 2000,
        clientHeight: 500,
      });
      act(() => {
        fireEvent.scroll(container);
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
