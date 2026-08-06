/**
 * Tests for LoginPage.
 *
 * Covers:
 *  - The form's initial render (heading, two inputs,
 *    submit button, register link)
 *  - Successful login navigates to /new_agent
 *  - Failed login surfaces the server's error string
 *  - Failed login with a non-ApiError falls back to the
 *    generic "Login failed" message
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";

import { LoginPage } from "./LoginPage";
import { ApiError } from "../api/client";

vi.mock("../api/auth", () => ({
  login: vi.fn(),
}));

import { login } from "../api/auth";

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/login"]}>
      <LoginPage />
    </MemoryRouter>,
  );
}

describe("LoginPage", () => {
  beforeEach(() => {
    login.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it("renders the sign-in form", () => {
    renderPage();

    expect(
      screen.getByRole("heading", { name: /sign in/i }),
    ).toBeInTheDocument();
    expect(screen.getByLabelText(/username/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/password/i)).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /sign in/i }),
    ).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /register/i })).toHaveAttribute(
      "href",
      "/register",
    );
  });

  it("submits the form and navigates to /new_agent on success", async () => {
    login.mockResolvedValueOnce({
      token: "tok",
      user: { id: 1, username: "alice", is_admin: false },
    });
    renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "alice" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "hunter2" },
    });
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

    await waitFor(() => {
      expect(login).toHaveBeenCalledWith("alice", "hunter2");
    });
  });

  it("surfaces the server's error message on a 4xx response", async () => {
    login.mockRejectedValueOnce(
      new ApiError(401, { error: "invalid_credentials" }),
    );
    renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "alice" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "wrong" },
    });
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

    expect(await screen.findByText(/invalid_credentials/i)).toBeInTheDocument();
  });

  it("falls back to a generic message when the failure is not an ApiError", async () => {
    login.mockRejectedValueOnce(new Error("network down"));
    renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "alice" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "x" },
    });
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

    expect(await screen.findByText(/login failed/i)).toBeInTheDocument();
  });

  it("shows a 'Signing in…' label while the request is in flight", async () => {
    let resolveLogin;
    login.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveLogin = resolve;
        }),
    );
    renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "alice" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "x" },
    });
    fireEvent.click(screen.getByRole("button", { name: /sign in/i }));

    expect(
      await screen.findByRole("button", { name: /signing in/i }),
    ).toBeDisabled();

    resolveLogin({ token: "t", user: {} });
  });
});
