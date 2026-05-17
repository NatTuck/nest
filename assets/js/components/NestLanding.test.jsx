import { describe, it, expect } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { NestLanding } from "../components/NestLanding";

describe("NestLanding", () => {
  it("renders the landing page with title and image", () => {
    render(<NestLanding />);

    // Check that the title is rendered
    expect(screen.getByText("A Nest of Agents")).toBeInTheDocument();

    // Check that the subtitle is rendered
    expect(
      screen.getByText(
        "Welcome to Nest - where intelligent agents collaborate and thrive",
      ),
    ).toBeInTheDocument();

    // Check that the image is rendered
    const image = screen.getByTestId("mascot-image");
    expect(image).toBeInTheDocument();
    expect(image).toHaveAttribute("src", "/images/nest-mascots.jpg");
    expect(image).toHaveAttribute("alt", "Nest Mascots");
  });

  it('renders the toggle button with initial "Flip Image" text', () => {
    render(<NestLanding />);

    const button = screen.getByTestId("toggle-button");
    expect(button).toBeInTheDocument();
    expect(button).toHaveTextContent("Flip Image");
  });

  it("image is not flipped initially", () => {
    render(<NestLanding />);

    const image = screen.getByTestId("mascot-image");
    // Initially, the transform should be scaleX(1) (no flip)
    expect(image).toHaveStyle({ transform: "scaleX(1)" });
  });

  it("flips the image horizontally when toggle button is clicked", () => {
    render(<NestLanding />);

    const button = screen.getByTestId("toggle-button");
    const image = screen.getByTestId("mascot-image");

    // Initially not flipped
    expect(image).toHaveStyle({ transform: "scaleX(1)" });
    expect(button).toHaveTextContent("Flip Image");

    // Click the toggle button
    fireEvent.click(button);

    // After click, the image should be flipped
    expect(image).toHaveStyle({ transform: "scaleX(-1)" });
    expect(button).toHaveTextContent("Flip Back");
  });

  it("flips the image back when toggle button is clicked again", () => {
    render(<NestLanding />);

    const button = screen.getByTestId("toggle-button");
    const image = screen.getByTestId("mascot-image");

    // Click to flip
    fireEvent.click(button);
    expect(image).toHaveStyle({ transform: "scaleX(-1)" });
    expect(button).toHaveTextContent("Flip Back");

    // Click again to flip back
    fireEvent.click(button);
    expect(image).toHaveStyle({ transform: "scaleX(1)" });
    expect(button).toHaveTextContent("Flip Image");
  });

  it("includes transition styles for smooth animation", () => {
    render(<NestLanding />);

    const image = screen.getByTestId("mascot-image");
    expect(image).toHaveStyle({ transition: "transform 0.3s ease-in-out" });
  });

  it("changes button color on mouse enter", () => {
    render(<NestLanding />);

    const button = screen.getByTestId("toggle-button");

    // Initial color
    expect(button).toHaveStyle({ backgroundColor: "#4f46e5" });

    // Hover
    fireEvent.mouseEnter(button);

    // Should change to hover color
    expect(button).toHaveStyle({ backgroundColor: "#4338ca" });
  });

  it("restores button color on mouse leave", () => {
    render(<NestLanding />);

    const button = screen.getByTestId("toggle-button");

    // Hover first
    fireEvent.mouseEnter(button);
    expect(button).toHaveStyle({ backgroundColor: "#4338ca" });

    // Mouse leave
    fireEvent.mouseLeave(button);

    // Should restore original color
    expect(button).toHaveStyle({ backgroundColor: "#4f46e5" });
  });
});
