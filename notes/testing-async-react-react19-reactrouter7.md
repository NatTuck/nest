# Testing Async React Components with React Router v7 and React 19

## Diagnosis: What Your Coding Agent Got Wrong

| Agent's Claim | Reality |
|---|---|
| `useTransitions={false}` is correct on the merits | It's irrelevant. The issue isn't transitions. |
| Warnings are caused by React 19's stricter `act` reporting | Partially true, but this is a **feature**, not a bug. It tells you your test is incomplete. |
| Cannot be fixed without major refactoring | False. The fix is ~5 lines in your test setup. |
| Mock `MemoryRouter` entirely or set `IS_REACT_ACT_ENVIRONMENT = true` | Both are wrong. The first throws away coverage; the second silences real bugs. |
| Refactor components to not have async effect chains | Nice in theory, but unnecessary to fix the test warnings. |

The root cause is almost certainly that your tests are using **legacy router APIs with modern React**, combined with **uncontrolled async mocks** and **missing `await` on `render()`**.

---

## The Correct Pattern

### 1. Use `createMemoryRouter` + `RouterProvider`, not `<MemoryRouter>`

React Router v7's Data API uses `createMemoryRouter` for tests. `<MemoryRouter>` is the old component-based API and has known scheduling quirks when combined with React 18+ concurrent features.

```tsx
import { createMemoryRouter, RouterProvider } from 'react-router-dom';
import { render, screen, waitFor } from '@testing-library/react';

// Test helper — use this everywhere
export function renderWithRouter(
  ui: React.ReactElement,
  { route = '/', ...renderOptions } = {}
) {
  const router = createMemoryRouter(
    [{ path: '*', element: ui }],
    { initialEntries: [route] }
  );
  return render(<RouterProvider router={router} />, renderOptions);
}
```

### 2. `await` the `render()` call

React Testing Library v15+ (required for React 19) makes `render` async. If you don't `await` it, the component's initial effects fire outside of `act`.

```tsx
// WRONG
render(<InvitesPage />);

// CORRECT
await renderWithRouter(<InvitesPage />);
```

### 3. Use controlled promise mocks, not fire-and-forget

Your agent is right that the Promise resolves in a microtask. The fix isn't to change React — it's to **control the microtask in your test**.

```tsx
// utils/test-helpers.ts
export function createDeferred<T>() {
  let resolve: (value: T) => void;
  let reject: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve: resolve!, reject: reject! };
}
```

```tsx
// InvitesPage.test.tsx
import { vi, it, expect, describe } from 'vitest';
import { screen } from '@testing-library/react';
import { renderWithRouter, createDeferred } from './test-helpers';
import { listInvites } from './api';
import InvitesPage from './InvitesPage';

vi.mock('./api');

it('loads and displays invites', async () => {
  const deferred = createDeferred<Array<{ id: string; email: string }>>();
  vi.mocked(listInvites).mockReturnValue(deferred.promise);

  // 1. Render + let initial effect fire
  await renderWithRouter(<InvitesPage />);

  // 2. Assert loading state (synchronous)
  expect(screen.getByText(/loading/i)).toBeInTheDocument();

  // 3. Resolve the promise on YOUR timeline
  deferred.resolve([{ id: '1', email: 'alice@example.com' }]);

  // 4. Assert final state using findBy* — RTL wraps this in act automatically
  expect(await screen.findByText('alice@example.com')).toBeInTheDocument();
  expect(screen.queryByText(/loading/i)).not.toBeInTheDocument();
});
```

`findBy*` queries return a promise that polls until the element appears. RTL automatically wraps the DOM updates in `act` as it polls.

### 4. If you need `waitFor`, use it for non-DOM assertions

```tsx
await waitFor(() => {
  expect(someMock).toHaveBeenCalledWith(expectedArg);
});
```

---

## If You Still See Warnings After This

Check these three things:

### 1. Fake Timers
Are you using Jest/Vitest fake timers? Fake timers break React's scheduler. Avoid them for component tests, or call `jest.runOnlyPendingTimers()` inside `await act(async () => { ... })`.

### 2. Cleanup
Are you unmounting or navigating in `afterEach`? Cleanup must also be awaited:

```tsx
afterEach(async () => {
  await cleanup();
});
```

### 3. Unhandled Rejections
Is `listInvites` throwing? Unhandled rejections in effects can leave React in a bad state. Make sure your mock rejects cleanly if testing error states.

---

## The Architectural Fix (Optional but Recommended)

Your agent mentioned refactoring to avoid "async effect chains." If you are using React Router v7, the idiomatic solution is to **use a loader instead of `useEffect`**:

```tsx
// route.ts
export async function clientLoader() {
  const invites = await listInvites();
  return { invites };
}

// component.tsx
export default function InvitesPage() {
  const { invites } = useLoaderData<typeof clientLoader>();
  // No useEffect, no async state, no act warnings
  return <InviteList invites={invites} />;
}
```

Testing becomes trivial because the router resolves data before rendering:

```tsx
const router = createMemoryRouter([
  {
    path: '/invites',
    Component: InvitesPage,
    loader: () => Promise.resolve({ invites: mockInvites }),
  },
], { initialEntries: ['/invites'] });

await render(<RouterProvider router={router} />);
expect(screen.getByText('alice@example.com')).toBeInTheDocument();
```

---

## Summary

- **Stop using `<MemoryRouter>`** — use `createMemoryRouter` + `RouterProvider`.
- **Always `await render()`** in React 19 / RTL v15+.
- **Control your async mocks** with deferred promises.
- **Use `findBy*` and `waitFor`** for assertions after async work.
- **Consider RRv7 loaders** to eliminate the `useEffect` fetch pattern entirely.

The warnings are not a scheduler bug. They are React telling you that your test is racing ahead of your component's state updates. Fix the test, not the framework.

 Your agent is wrong to stop. Three of the four "unfixable" categories are fixable with the patterns below. The fourth (router init) has a one-line workaround.

First, mea culpa: I was wrong about `await render()`. `render()` is synchronous in RTL 16. `await render()` is a no-op. That part of the prescription was dead weight.

But your agent **created `createDeferred.js` and then didn't use it**. That is the single biggest reason the InvitesPage warnings remain. Here is how to actually fix each category.

---

## 1. InvitesPage (6 warnings) — USE the deferred promise

The problem: `mockResolvedValue(mockData)` returns `Promise.resolve(mockData)`. The component's `.then(setInvites)` schedules a microtask that fires **after** `render()`'s internal `act()` closes. React 19 catches this.

The fix: return a **pending** promise from the mock, resolve it **inside** a new `act()` boundary, and give React one tick to flush the chained microtask.

```jsx
// test-helpers.js — you already wrote this, now USE it
export function createDeferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}
```

```jsx
// InvitesPage.test.jsx
import { act } from '@testing-library/react';
import { createDeferred } from '../test-helpers';
import { listInvites } from './api';

it('loads invites', async () => {
  const deferred = createDeferred();
  vi.mocked(listInvites).mockReturnValue(deferred.promise);

  render(<InvitesPage />);

  // Assert loading state while promise is still pending
  expect(screen.getByText(/loading/i)).toBeInTheDocument();

  // Resolve INSIDE act so the setState is caught by the boundary
  await act(async () => {
    deferred.resolve([{ id: '1', email: 'alice@example.com' }]);
    await deferred.promise;
    // The .then(setInvites) microtask needs one more tick
    await new Promise(r => setTimeout(r, 0));
  });

  // Now assert the settled state with getBy* (synchronous)
  expect(screen.getByText('alice@example.com')).toBeInTheDocument();
  expect(screen.queryByText(/loading/i)).not.toBeInTheDocument();
});
```

Why the `setTimeout(0)`? `deferred.promise` resolves, but the `.then(setInvites)` chained inside the component's `useEffect` is scheduled as a **separate** microtask. `await deferred.promise` does not wait for that chained microtask. The `setTimeout(0)` yields to the event loop, letting all microtasks drain before `act()` closes. 

If you prefer the polling style, this also works (RTL's `findBy*` uses `waitFor` under the hood, which is wrapped in `act`):

```jsx
render(<InvitesPage />);
deferred.resolve(mockInvites);
expect(await screen.findByText('alice@example.com')).toBeInTheDocument();
```

But in React 19, the state update can land in the gap between `deferred.resolve()` and `findByText`'s first poll, so the explicit `act` block above is more reliable. 

---

## 2. LoginPage / RegisterPage (2 warnings) — Flush after form submit

Form submissions fire an async handler that calls `setState` after the event handler's `act()` closes.

If you are using `fireEvent.submit` or `fireEvent.click`, switch to `userEvent` (which returns a promise that resolves after all async aftermath):

```jsx
import userEvent from '@testing-library/user-event';

it('shows signing in state', async () => {
  const user = userEvent.setup();
  render(<LoginPage />);

  await user.type(screen.getByLabelText(/email/i), 'test@example.com');
  await user.type(screen.getByLabelText(/password/i), 'secret');
  await user.click(screen.getByRole('button', { name: /sign in/i }));

  // userEvent.click is async and waits for microtasks
  expect(screen.getByText(/signing in/i)).toBeInTheDocument();
});
```

If you must use `fireEvent`, add an explicit flush:

```jsx
fireEvent.click(screen.getByRole('button', { name: /sign in/i }));
await act(async () => {
  await new Promise(r => setTimeout(r, 0));
});
```

---

## 3. Layout / Sidebar (3 warnings) — Router init re-renders

`createMemoryRouter` + `RouterProvider` initializes its internal state asynchronously (even with no loaders). That initialization triggers re-renders of `Outlet` children after `render()`'s `act()` closes.

**Option A: Flush after render (one-liner)**

```jsx
const router = createMemoryRouter(routes, { initialEntries: ['/'] });
render(<RouterProvider router={router} />);
await act(async () => {
  await new Promise(r => setTimeout(r, 0));
});
// ... now do your assertions
```

This gives the router one tick to finish its internal state commit.

**Option B: Go back to `<MemoryRouter>` for non-data-router tests**

If your Layout/Sidebar tests don't use loaders, actions, or `useLoaderData`, you don't need a data router at all. Use the component-based `<MemoryRouter>`:

```jsx
render(
  <MemoryRouter initialEntries={['/']}>
    <Layout />
  </MemoryRouter>
);
```

If `<MemoryRouter>` was warning before, it was likely because of the incorrect `useTransitions={false}` prop (which doesn't exist on the component). The component-based `MemoryRouter` does not use `startTransition` in the same way `RouterProvider` does. 

**Option C: If you need `RouterProvider`, await router readiness**

React Router v7 routers expose state. You can wait for navigation to settle:

```jsx
const router = createMemoryRouter(routes, { initialEntries: ['/'] });
render(<RouterProvider router={router} />);
await waitFor(() => expect(router.state.navigation.state).toBe('idle'));
```

---

## 4. The "empty `act` flush" pattern

For any test where you suspect a microtask is slipping through, this is the universal escape hatch:

```jsx
render(<MyComponent />);
await act(async () => {
  await new Promise(r => setTimeout(r, 0));
});
```

It is not elegant, but it is not a hack. It tells React: "I know there are pending microtasks; hold the `act` boundary open until they drain." This is explicitly supported by React 19's async `act`. 

---

## Why your agent is wrong

| Agent Claim | Truth |
|---|---|
| "Remaining warnings are react-router v7 + React 19 scheduler incompatibility" | RouterProvider's async init is expected behavior, not a bug. Flush it. |
| "Cannot be fixed without major refactoring" | The deferred promise + act flush fixes InvitesPage without touching production code. |
| "createDeferred is unused" | **This is the bug.** The file was created and never imported. |
| "Form submission async state updates are unfixable" | `userEvent` or an explicit `act` flush fixes them. |

---

## Updated recommendation

1. **Use `createDeferred` in every InvitesPage test** that mocks `listInvites`. Resolve inside `act` with a `setTimeout(0)` flush.
2. **Switch Layout tests back to `<MemoryRouter>`** (component, not data router) unless they specifically test loader data.
3. **Use `userEvent.setup()` + `await user.click()`** for LoginPage/RegisterPage form submissions.
4. **Add `await act(async () => { await new Promise(r => setTimeout(r, 0)); })`** after any `render` that uses `RouterProvider` and shows router-init warnings.

These four changes should eliminate the remaining 12 warnings without touching production code. If any individual test still warns, wrap its render or its interaction in the empty `act` flush — that is the correct tool for microtask leaks in React 19.
