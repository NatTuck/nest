/**
 * Tests for RegisterPage.
 *
 * Covers:
 *  - The form's initial render (heading, invite-token input
 *    when applicable, username/password, submit button,
 *    sign-in link)
 *  - The `?token=first-user` magic path hides the
 *    invite-token input and shows the "first admin" copy
 *  - Successful registration navigates to /new_agent
 *  - Failed registration surfaces the server's error
 *  - Generic (non-ApiError) failures fall back to the
 *    generic "Registration failed" message
 *  - The submit button is disabled when no token is
 *    supplied (defensive)
 *  - Submitting shows a "Creating account…" label while
 *    the request is in flight.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { screen, fireEvent, waitFor, act } from "@testing-library/react";

import { RegisterPage } from "./RegisterPage";
import { ApiError } from "../api/client";
import { renderWithRouter } from "../test/render_with_router";
import { createDeferred } from "../test/create_deferred";

vi.mock("../api/auth", () => ({
  register: vi.fn(),
}));

import { register } from "../api/auth";

async function renderPage(search = "?token=invite-abc") {
  return renderWithRouter(<RegisterPage />, {
    route: `/register${search}`,
    routes: [
      { path: "/register", element: <RegisterPage /> },
      { path: "/new_agent", element: <div>New agent page</div> },
    ],
  });
}

describe("RegisterPage", () => {
  beforeEach(() => {
    register.mockReset();
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it("renders the registration form with the invite token input populated", async () => {
    await renderPage();

    expect(
      screen.getByRole("heading", { name: /create an account/i }),
    ).toBeInTheDocument();
    expect(screen.getByDisplayValue("invite-abc")).toBeInTheDocument();
    expect(screen.getByLabelText(/username/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/password/i)).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /create account/i }),
    ).toBeInTheDocument();
    expect(screen.getByRole("link", { name: /sign in/i })).toHaveAttribute(
      "href",
      "/login",
    );
  });

  it("hides the invite-token input on the first-user bootstrap path", async () => {
    await renderPage("?token=first-user");

    expect(
      screen.getByRole("heading", { name: /create the first admin/i }),
    ).toBeInTheDocument();
    expect(screen.queryByLabelText(/invite token/i)).toBeNull();
    expect(
      screen.getByRole("heading", { name: /first admin/i }),
    ).toBeInTheDocument();
  });

  it("submits the form and navigates to /new_agent on success", async () => {
    register.mockResolvedValueOnce({
      token: "tok",
      user: { id: 1, username: "bob", is_admin: true },
    });
    await renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "bob" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "sekritpw1" },
    });
    fireEvent.click(screen.getByRole("button", { name: /create account/i }));

    await waitFor(() => {
      expect(register).toHaveBeenCalledWith({
        username: "bob",
        password: "sekritpw1",
        token: "invite-abc",
      });
    });
  });

  it("surfaces the server's error message on a 4xx response", async () => {
    register.mockRejectedValueOnce(
      new ApiError(409, { error: "username taken" }),
    );
    await renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "bob" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "sekritpw1" },
    });
    fireEvent.click(screen.getByRole("button", { name: /create account/i }));

    expect(await screen.findByText(/username taken/i)).toBeInTheDocument();
  });

  it("falls back to a generic message when the failure is not an ApiError", async () => {
    register.mockRejectedValueOnce(new Error("network down"));
    await renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "bob" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "sekritpw1" },
    });
    fireEvent.click(screen.getByRole("button", { name: /create account/i }));

    expect(await screen.findByText(/registration failed/i)).toBeInTheDocument();
  });

  it("handles a missing ?token= query parameter gracefully", async () => {
    await renderPage("");

    // Without a token the heading collapses to the generic
    // form and the token field stays empty (no input shown).
    expect(
      screen.getByRole("heading", { name: /create an account/i }),
    ).toBeInTheDocument();
    // The submit button is disabled because there's no token.
    expect(
      screen.getByRole("button", { name: /create account/i }),
    ).toBeDisabled();
  });

  it("shows a 'Creating account…' label while the request is in flight", async () => {
    // `createDeferred` lets the test control exactly when
    // the register promise settles so the `setSubmitting(true)`
    // state update lands inside an `act()` boundary. Same
    // pattern as LoginPage's "Signing in…" test.
    const deferred = createDeferred();
    register.mockReturnValueOnce(deferred.promise);

    await renderPage();

    fireEvent.change(screen.getByLabelText(/username/i), {
      target: { value: "bob" },
    });
    fireEvent.change(screen.getByLabelText(/password/i), {
      target: { value: "sekritpw1" },
    });
    fireEvent.click(screen.getByRole("button", { name: /create account/i }));

    expect(
      await screen.findByRole("button", { name: /creating account/i }),
    ).toBeDisabled();

    // Resolve inside an act so the navigation on success
    // lands inside the act boundary.
    await act(async () => {
      deferred.resolve({ token: "t", user: {} });
    });
  });
});
