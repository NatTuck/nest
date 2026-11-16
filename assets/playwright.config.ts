/**
 * The end-to-end suite: a real browser against a real server.
 *
 * `webServer` runs `scripts/e2e/start.sh`, which is the same command a developer
 * runs by hand — the database, the seeded user, the stub provider and the built
 * bundle all come from there, so nothing the suite needs is configured twice.
 * Playwright waits on `/login` answering rather than on a clock, and stops the
 * script (and with it the server and the stub) when the run ends.
 *
 * `reuseExistingServer` is off in CI on purpose: a runner that happens to have
 * something on the port must fail loudly rather than test the wrong process. A
 * developer's already-running server is reused, which is what makes a second
 * `pnpm e2e` fast.
 *
 * The `setup` project signs the seeded user in once and writes the browser's
 * storage state (the token lives in `localStorage`), so every other project
 * starts from a signed-in session without repeating the form in each spec.
 *
 * The one test project is the phone: 390x844 is the viewport the phone layout
 * was built against, `isMobile`/`hasTouch` make it a touch device rather than a
 * narrow desktop, and `deviceScaleFactor: 2` is a phone's pixel ratio. The
 * desktop layout is covered by the unit tests; this suite exists to prove the
 * app works end to end on the screen it is hardest to fit.
 */
import { defineConfig } from "playwright/test";

const baseURL = "http://127.0.0.1:4010";

export default defineConfig({
  testDir: "./e2e",
  // Artifacts land next to the suite (`/assets/test-results`, gitignored).
  outputDir: "./test-results",
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 1 : 0,
  // One worker: the specs share one server and one database. They create their
  // own space and agent, so they could run in parallel, but the suite is a few
  // seconds either way and a single worker makes the log one story in order.
  workers: 1,
  reporter: [["html", { open: "never" }], ["list"]],
  use: {
    baseURL,
    trace: "on-first-retry",
  },
  projects: [
    {
      name: "setup",
      testMatch: /.*\.setup\.ts/,
    },
    {
      name: "phone",
      dependencies: ["setup"],
      use: {
        viewport: { width: 390, height: 844 },
        isMobile: true,
        hasTouch: true,
        deviceScaleFactor: 2,
        storageState: "./e2e/.auth/state.json",
      },
    },
  ],
  webServer: {
    command: "bash ../scripts/e2e/start.sh",
    url: `${baseURL}/login`,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    // The server's own log is the only place a boot failure is visible, and it
    // is the thing a red run needs. Piped, not ignored.
    stdout: "pipe",
    stderr: "pipe",
  },
});
