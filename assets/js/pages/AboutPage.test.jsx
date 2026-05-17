/**
 * AboutPage Component Tests
 *
 * Tests the flip behavior and rendering of the About page.
 */

import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { AboutPage } from "./AboutPage";

describe("AboutPage", () => {
  it("renders the page with initial state", () => {
    render(<AboutPage />);

    // Check title
    expect(screen.getByText("A Nest of Agents")).toBeInTheDocument();

    // Check subtitle
    expect(
      screen.getByText(
        "Welcome to Nest — where intelligent agents collaborate and thrive",
      ),
    ).toBeInTheDocument();

    // Check image is rendered
    const image = screen.getByTestId("mascot-image");
    expect(image).toBeInTheDocument();
    expect(image).toHaveAttribute("alt", "Nest Mascots");

    // Image should not be flipped initially (scale-x-100)
    expect(image.className).toContain("scale-x-100");
    expect(image.className).not.toContain("-scale-x-100");
  });

  it("renders the flip button with correct initial text", () => {
    render(<AboutPage />);

    const button = screen.getByTestId("toggle-button");
    expect(button).toBeInTheDocument();
    expect(button).toHaveTextContent("Flip Image");
  });

  it("flips the image horizontally when button is clicked", () => {
    render(<AboutPage />);

    const button = screen.getByTestId("toggle-button");
    const image = screen.getByTestId("mascot-image");

    // Initial state
    expect(image.className).toContain("scale-x-100");
    expect(image.className).not.toContain("-scale-x-100");
    expect(button).toHaveTextContent("Flip Image");

    // Click to flip
    fireEvent.click(button);

    // Image should be flipped (-scale-x-100 mirrors horizontally)
    expect(image.className).toContain("-scale-x-100");
    // Make sure it doesn't have the positive scale-x-100 (check with space prefix)
    expect(image.className).not.toMatch(/\sscale-x-100/);
    expect(button).toHaveTextContent("Flip Back");
  });

  it("flips back to normal when button is clicked twice", () => {
    render(<AboutPage />);

    const button = screen.getByTestId("toggle-button");
    const image = screen.getByTestId("mascot-image");

    // Click twice
    fireEvent.click(button);
    fireEvent.click(button);

    // Should be back to normal
    expect(image.className).toContain("scale-x-100");
    expect(image.className).not.toContain("-scale-x-100");
    expect(button).toHaveTextContent("Flip Image");
  });

  it("renders the description content", () => {
    render(<AboutPage />);

    expect(screen.getByText("What is Nest?")).toBeInTheDocument();
    expect(
      screen.getByText(
        /Nest is a platform for creating and managing AI agents/,
      ),
    ).toBeInTheDocument();
  });

  it("renders the features list", () => {
    render(<AboutPage />);

    expect(screen.getByText("Features")).toBeInTheDocument();
    expect(screen.getByText(/Multiple Agents:/)).toBeInTheDocument();
    expect(screen.getByText(/Real-time Chat:/)).toBeInTheDocument();
    expect(screen.getByText(/Model Selection:/)).toBeInTheDocument();
    expect(screen.getByText(/Persistent Sessions:/)).toBeInTheDocument();
  });

  it("renders the getting started section", () => {
    render(<AboutPage />);

    expect(screen.getByText("Getting Started")).toBeInTheDocument();
    expect(
      screen.getByText(/Click "New Agent" in the sidebar/),
    ).toBeInTheDocument();
  });

  it("renders the footer", () => {
    render(<AboutPage />);

    expect(
      screen.getByText("Built with Phoenix, React, and LangChain"),
    ).toBeInTheDocument();
  });

  it("applies transition classes to the image", () => {
    render(<AboutPage />);

    const image = screen.getByTestId("mascot-image");

    // Should have transition classes
    expect(image.className).toContain("transition-transform");
    expect(image.className).toContain("duration-300");
    expect(image.className).toContain("ease-in-out");
  });

  it("button has proper accessibility attributes", () => {
    render(<AboutPage />);

    const button = screen.getByTestId("toggle-button");
    expect(button).toHaveAttribute("type", "button");
  });
});
