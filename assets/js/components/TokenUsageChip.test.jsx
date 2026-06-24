/**
 * TokenUsageChip Component Tests
 *
 * Covers:
 * - Hides entirely when contextLimit is null/undefined/zero/negative
 * - Renders the one-line collapsed view (used/limit + percentage)
 * - Click toggles the expanded view (Last / Session / Est.)
 * - "Last" line omits the "+ N cached" suffix when no cache is in play
 * - "Last" line includes "+ N cached" when cache_read > 0
 * - Progress bar aria values reflect the inputs (and the total
 *   context fill, not just `input_tokens`)
 * - Clamps percentage at 100 when used exceeds limit
 * - Falls back to `input_tokens` (or 0) when `context_input_tokens`
 *   is missing (older wire payload)
 * - Cost label reflects the cumulative session cost
 */

import { describe, it, expect, afterEach } from "vitest";
import { render, screen, cleanup, fireEvent } from "@testing-library/react";
import { TokenUsageChip, formatTokens } from "./TokenUsageChip";

afterEach(() => {
  cleanup();
});

describe("TokenUsageChip", () => {
  describe("visibility", () => {
    it("renders nothing when contextLimit is null", () => {
      const { container } = render(
        <TokenUsageChip usage={{ input_tokens: 100 }} contextLimit={null} />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when contextLimit is undefined", () => {
      const { container } = render(
        <TokenUsageChip usage={{ input_tokens: 100 }} />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when contextLimit is zero", () => {
      const { container } = render(
        <TokenUsageChip usage={{ input_tokens: 100 }} contextLimit={0} />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when contextLimit is negative", () => {
      const { container } = render(
        <TokenUsageChip usage={{ input_tokens: 100 }} contextLimit={-1} />,
      );
      expect(container.firstChild).toBeNull();
    });
  });

  describe("collapsed view (default)", () => {
    it("renders used/limit, percentage, and a progress bar", () => {
      render(
        <TokenUsageChip
          usage={{ input_tokens: 12345 }}
          contextLimit={128000}
        />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip).toBeInTheDocument();
      expect(chip.textContent).toContain("12,345");
      expect(chip.textContent).toContain("128,000");
      expect(chip.textContent).toContain("tokens");
      // 12345 / 128000 = 0.09644... -> "9.6%"
      expect(chip.textContent).toContain("9.6%");

      // Expanded details are NOT in the DOM until clicked.
      expect(
        document.querySelector('[data-testid="token-usage-details"]'),
      ).toBeNull();
    });

    it("uses context_input_tokens (input + cache) for the numerator when present", () => {
      // The full context for the most recent call is 12345
      // (new) + 3200 (cached) = 15545. The chip should display
      // 15545 / 256000, not 12345.
      render(
        <TokenUsageChip
          usage={{
            input_tokens: 12345,
            cache_read_input_tokens: 3200,
            context_input_tokens: 15545,
          }}
          contextLimit={256000}
        />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("15,545");
      expect(chip.textContent).toContain("256,000");

      const bar = screen.getByRole("progressbar");
      expect(bar).toHaveAttribute("aria-valuenow", "15545");
      expect(bar).toHaveAttribute("aria-valuemax", "256000");
    });

    it("falls back to input_tokens when context_input_tokens is missing (old wire)", () => {
      // Backward compat: a server that hasn't been updated yet
      // doesn't include `context_input_tokens`. The chip should
      // still display something sensible — the bare
      // `input_tokens` value.
      render(
        <TokenUsageChip usage={{ input_tokens: 100 }} contextLimit={1000} />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("100");
    });

    it("falls back to input + cache_read + cache_creation when context_input_tokens is missing but cache fields are present", () => {
      // Mixed-version scenario: server emits the new cache
      // fields but the derived `context_input_tokens` field
      // hasn't been wired up yet.
      render(
        <TokenUsageChip
          usage={{
            input_tokens: 100,
            cache_read_input_tokens: 50,
            cache_creation_input_tokens: 25,
          }}
          contextLimit={1000}
        />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("175");
    });

    it("clamps the percentage at 100 when used exceeds limit", () => {
      render(
        <TokenUsageChip
          usage={{ input_tokens: 150000 }}
          contextLimit={100000}
        />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("100.0%");
      const bar = screen.getByRole("progressbar");
      expect(bar).toHaveAttribute("aria-valuenow", "150000");
      expect(bar).toHaveAttribute("aria-valuemax", "100000");
    });

    it("treats a null usage as 0 tokens", () => {
      render(<TokenUsageChip usage={null} contextLimit={128000} />);

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0 / 128,000 tokens");
    });

    it("treats a NaN token field as 0", () => {
      render(
        <TokenUsageChip
          usage={{ input_tokens: Number.NaN }}
          contextLimit={128000}
        />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0 / 128,000");
    });

    it("clamps a negative token count to 0", () => {
      render(
        <TokenUsageChip usage={{ input_tokens: -50 }} contextLimit={128000} />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0 / 128,000 tokens");
    });

    it("uses 0% rounding for very small fractions", () => {
      render(
        <TokenUsageChip usage={{ input_tokens: 1 }} contextLimit={1000000} />,
      );

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0.0%");
    });

    it("sets aria-label on the progressbar", () => {
      render(
        <TokenUsageChip usage={{ input_tokens: 42 }} contextLimit={100} />,
      );
      const bar = screen.getByRole("progressbar");
      expect(bar).toHaveAttribute("aria-label", "Context window usage");
    });
  });

  describe("expanded view (after click)", () => {
    it("does not show details until the chip is clicked", () => {
      render(
        <TokenUsageChip
          usage={{
            input_tokens: 100,
            total_input_tokens: 1000,
            output_tokens: 200,
          }}
          contextLimit={1000}
        />,
      );

      expect(
        document.querySelector('[data-testid="token-usage-details"]'),
      ).toBeNull();
    });

    it("shows the Last / Session / Est. lines on click", () => {
      render(
        <TokenUsageChip
          usage={{
            input_tokens: 4821,
            cache_read_input_tokens: 3200,
            context_input_tokens: 8021,
            total_input_tokens: 25_000,
            output_tokens: 8000,
          }}
          contextLimit={256000}
        />,
      );

      const toggle = screen.getByRole("button", {
        name: /toggle token usage details/i,
      });
      fireEvent.click(toggle);

      const details = document.querySelector(
        '[data-testid="token-usage-details"]',
      );
      expect(details).toBeInTheDocument();
      // Last line: per-call breakdown, includes cache.
      expect(details.textContent).toContain("Last:");
      expect(details.textContent).toContain("4,821 new");
      expect(details.textContent).toContain("3,200 cached");
      // Session line: cumulative in/out.
      expect(details.textContent).toContain("Session:");
      expect(details.textContent).toContain("25,000 in");
      expect(details.textContent).toContain("8,000 out");
      // Cost line: present and formatted as USD.
      expect(details.textContent).toContain("Est. $");
    });

    it("hides the cached suffix on the Last line when cache_read is 0", () => {
      render(
        <TokenUsageChip
          usage={{
            input_tokens: 1000,
            cache_read_input_tokens: 0,
            total_input_tokens: 1000,
            output_tokens: 500,
          }}
          contextLimit={10000}
        />,
      );

      fireEvent.click(
        screen.getByRole("button", { name: /toggle token usage details/i }),
      );

      const details = document.querySelector(
        '[data-testid="token-usage-details"]',
      );
      expect(details.textContent).toContain("1,000 new");
      expect(details.textContent).not.toContain("cached");
    });

    it("hides the cached suffix when cache_read is missing entirely", () => {
      render(
        <TokenUsageChip
          usage={{
            input_tokens: 1000,
            total_input_tokens: 1000,
            output_tokens: 500,
          }}
          contextLimit={10000}
        />,
      );

      fireEvent.click(
        screen.getByRole("button", { name: /toggle token usage details/i }),
      );

      const details = document.querySelector(
        '[data-testid="token-usage-details"]',
      );
      expect(details.textContent).toContain("1,000 new");
      expect(details.textContent).not.toContain("cached");
    });

    it("collapses back to one line on a second click", () => {
      render(
        <TokenUsageChip
          usage={{
            input_tokens: 1000,
            total_input_tokens: 1000,
            output_tokens: 500,
          }}
          contextLimit={10000}
        />,
      );

      const toggle = screen.getByRole("button", {
        name: /toggle token usage details/i,
      });
      fireEvent.click(toggle);
      expect(
        document.querySelector('[data-testid="token-usage-details"]'),
      ).toBeInTheDocument();

      fireEvent.click(toggle);
      expect(
        document.querySelector('[data-testid="token-usage-details"]'),
      ).toBeNull();
    });

    it("reflects the cumulative session cost in the Est. line", () => {
      // 1M input @ $1 + 1M output @ $4 = $5.00
      render(
        <TokenUsageChip
          usage={{
            total_input_tokens: 1_000_000,
            output_tokens: 1_000_000,
          }}
          contextLimit={10_000_000}
        />,
      );

      fireEvent.click(
        screen.getByRole("button", { name: /toggle token usage details/i }),
      );

      const cost = document.querySelector('[data-testid="token-usage-cost"]');
      expect(cost.textContent).toContain("$5.00");
    });

    it("reflects cache discount in the cost estimate", () => {
      // 1M input @ $1 + 1M cached @ $0.25 + 1M output @ $4 = $5.25
      // (vs $5.50 if the cache were billed at input rate)
      render(
        <TokenUsageChip
          usage={{
            total_input_tokens: 1_000_000,
            total_cache_read_input_tokens: 1_000_000,
            output_tokens: 1_000_000,
          }}
          contextLimit={10_000_000}
        />,
      );

      fireEvent.click(
        screen.getByRole("button", { name: /toggle token usage details/i }),
      );

      const cost = document.querySelector('[data-testid="token-usage-cost"]');
      expect(cost.textContent).toContain("$5.25");
    });

    it("treats missing session fields as 0 in the cost line", () => {
      // No usage data at all — cost is $0.00.
      render(<TokenUsageChip usage={null} contextLimit={1000} />);

      fireEvent.click(
        screen.getByRole("button", { name: /toggle token usage details/i }),
      );

      const cost = document.querySelector('[data-testid="token-usage-cost"]');
      expect(cost.textContent).toContain("$0.00");
    });

    it("sets aria-expanded on the toggle button", () => {
      render(
        <TokenUsageChip usage={{ input_tokens: 100 }} contextLimit={1000} />,
      );

      const toggle = screen.getByRole("button", {
        name: /toggle token usage details/i,
      });
      expect(toggle).toHaveAttribute("aria-expanded", "false");

      fireEvent.click(toggle);
      expect(toggle).toHaveAttribute("aria-expanded", "true");
    });
  });
});

describe("formatTokens", () => {
  it("formats integers with thousands separators", () => {
    expect(formatTokens(0)).toBe("0");
    expect(formatTokens(1000)).toBe("1,000");
    expect(formatTokens(12345)).toBe("12,345");
    expect(formatTokens(1234567)).toBe("1,234,567");
  });

  it("rounds non-integer values", () => {
    expect(formatTokens(1234.6)).toBe("1,235");
    expect(formatTokens(1234.4)).toBe("1,234");
  });

  it("returns 0 for non-finite values", () => {
    expect(formatTokens(Number.NaN)).toBe("0");
    expect(formatTokens(Number.POSITIVE_INFINITY)).toBe("0");
  });
});
