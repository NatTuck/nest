/**
 * Test helper for rendering components that depend on
 * react-router v7.
 *
 * Uses `<MemoryRouter>` + `<Routes>` + `<Route>` directly —
 * no `createMemoryRouter` / `RouterProvider`. The data API
 * is forbidden in production (see `App.jsx`); tests mirror
 * the same simple shape so the component under test renders
 * exactly the same way it does in production.
 *
 * Usage:
 *
 *     renderWithRouter(<InvitesPage />, { route: "/invites" });
 *     renderWithRouter(<Page />);  // defaults to "/"
 *
 * Pass `routes` to specify a list of `path`/`element`
 * pairs. The default is `[{ path: "*", element: ui }]`
 * which is fine for components that don't use `<Outlet />`
 * or `<Navigate />` to switch routes.
 */
import { act, render } from "@testing-library/react";
import { MemoryRouter, Routes, Route } from "react-router-dom";

/**
 * Render the component under test inside a
 * `<MemoryRouter>` + `<Routes>` + `<Route>` so the
 * production-shape router is exercised.
 *
 * React Router v7.15 + React 19 + RTL 16 combo: the
 * router's `useSyncExternalStore` scheduler fires an
 * async route-commit AFTER `render()`'s internal sync
 * `act` closes, producing "An update to <Component>
 * inside a test was not wrapped in act(...)" warnings.
 * We yield one microtask tick inside the wrapping
 * `act` so the pending commit lands inside the act
 * boundary. Callers `await renderWithRouter(...)`.
 */
export async function renderWithRouter(
  ui,
  { route = "/", routes, ...renderOptions } = {},
) {
  const resolvedRoutes = routes ?? [{ path: "*", element: ui }];
  let result;
  await act(async () => {
    result = render(
      <MemoryRouter initialEntries={[route]}>
        <Routes>
          {resolvedRoutes.map((r) => (
            <Route key={r.path} path={r.path} element={r.element} />
          ))}
        </Routes>
      </MemoryRouter>,
      renderOptions,
    );
    // Yield one microtask tick so any pending
    // `useSyncExternalStore` updates from the router
    // land inside the same `act` boundary. The async
    // form of `act` flushes all queued effects before
    // returning.
    await Promise.resolve();
  });
  return result;
}
