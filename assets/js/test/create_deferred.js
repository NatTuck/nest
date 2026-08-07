/**
 * Test helper for creating a deferred promise that the
 * test can resolve or reject manually, rather than relying
 * on `mockResolvedValueOnce`. This is the React 19 pattern
 * for testing components with async effects — the test
 * controls exactly when the promise settles, so the state
 * update lands inside an explicit `act()` block rather than
 * racing ahead of the test's assertions.
 *
 * Usage:
 *
 *     const deferred = createDeferred();
 *     listInvites.mockReturnValueOnce(deferred.promise);
 *     await renderWithRouter(<InvitesPage />);
 *     await act(async () => {
 *       deferred.resolve({ invites: [] });
 *     });
 *     expect(screen.getByText(/no invites yet/i)).toBeInTheDocument();
 */
export function createDeferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}
