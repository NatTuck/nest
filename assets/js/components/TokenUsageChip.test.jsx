/**
 * TokenUsageChip Component Tests
 *
 * Covers:
 * - Hides entirely when contextLimit is null/undefined/zero/negative
 * - Renders formatted used/limit and percentage
 * - Clamps percentage at 100
 * - Defaults lastInput to 0 when null/NaN
 * - Progressbar aria values reflect the inputs
 */

import { describe, it, expect, afterEach } from "vitest";
import { render, screen, cleanup } from "@testing-library/react";
import { TokenUsageChip, formatTokens } from "./TokenUsageChip";

afterEach(() => {
  cleanup();
});

describe("TokenUsageChip", () => {
  describe("visibility", () => {
    it("renders nothing when contextLimit is null", () => {
      const { container } = render(
        <TokenUsageChip lastInput={100} contextLimit={null} />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when contextLimit is undefined", () => {
      const { container } = render(<TokenUsageChip lastInput={100} />);
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when contextLimit is zero", () => {
      const { container } = render(
        <TokenUsageChip lastInput={100} contextLimit={0} />,
      );
      expect(container.firstChild).toBeNull();
    });

    it("renders nothing when contextLimit is negative", () => {
      const { container } = render(
        <TokenUsageChip lastInput={100} contextLimit={-1} />,
      );
      expect(container.firstChild).toBeNull();
    });
  });

  describe("rendered content", () => {
    it("renders used/limit and percentage with a valid contextLimit", () => {
      render(<TokenUsageChip lastInput={12345} contextLimit={128000} />);

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip).toBeInTheDocument();
      expect(chip.textContent).toContain("12,345");
      expect(chip.textContent).toContain("128,000");
      expect(chip.textContent).toContain("tokens");
      // 12345 / 128000 = 0.09644... → "9.6%"
      expect(chip.textContent).toContain("9.6%");
    });

    it("clamps the percentage at 100 when used exceeds limit", () => {
      render(<TokenUsageChip lastInput={150000} contextLimit={100000} />);

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("100.0%");
      const bar = screen.getByRole("progressbar");
      expect(bar).toHaveAttribute("aria-valuenow", "150000");
      expect(bar).toHaveAttribute("aria-valuemax", "100000");
    });

    it("treats a null lastInput as 0", () => {
      render(<TokenUsageChip lastInput={null} contextLimit={128000} />);

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0 / 128,000 tokens");
      expect(chip.textContent).toContain("0.0%");
    });

    it("treats a NaN lastInput as 0", () => {
      render(<TokenUsageChip lastInput={Number.NaN} contextLimit={128000} />);

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0 /");
    });

    it("clamps a negative lastInput to 0", () => {
      render(<TokenUsageChip lastInput={-50} contextLimit={128000} />);

      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0 / 128,000 tokens");
    });

    it("sets aria-valuemin, aria-valuemax, aria-valuenow on the progressbar", () => {
      render(<TokenUsageChip lastInput={42} contextLimit={100} />);
      const bar = screen.getByRole("progressbar");

      expect(bar).toHaveAttribute("aria-valuemin", "0");
      expect(bar).toHaveAttribute("aria-valuemax", "100");
      expect(bar).toHaveAttribute("aria-valuenow", "42");
      expect(bar).toHaveAttribute("aria-label", "Context window usage");
    });

    it("uses 0% rounding for very small fractions", () => {
      render(<TokenUsageChip lastInput={1} contextLimit={1000000} />);
      const chip = document.querySelector('[data-testid="token-usage-chip"]');
      expect(chip.textContent).toContain("0.0%");
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
