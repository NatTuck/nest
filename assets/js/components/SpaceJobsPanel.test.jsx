/**
 * SpaceJobsPanel tests (#225): the space-wide job list on the space page.
 *
 * The store is the real one — the panel's whole job is rendering what the
 * lobby's frames put there, so a live update is a `setSpaceJobs` away. The
 * channel actions are mocked: what is under test is which action a control
 * calls, and what the panel says in each of its three states (a list, a known
 * empty space, and no read yet — the last never rendered as "no jobs").
 */
import { describe, it, beforeEach, expect, vi } from "vitest";
import {
  render,
  screen,
  fireEvent,
  waitFor,
  act,
} from "@testing-library/react";
import { useStore } from "../store";
import { refreshSpaceJobs, killSpaceJob, fetchSpaceJobLog } from "../channels";
import { SpaceJobsPanel } from "./SpaceJobsPanel";

vi.mock("../channels", () => ({
  refreshSpaceJobs: vi.fn(),
  killSpaceJob: vi.fn(),
  fetchSpaceJobLog: vi.fn(),
}));

const running = {
  id: "job-a",
  agent: "alice",
  command: "sleep 30",
  status: "running",
  exit_code: null,
  killed: false,
  log_path: "/tmp/alice/shell-jobs/job-a.log",
};

beforeEach(() => {
  useStore.getState()._reset();
  vi.clearAllMocks();
  refreshSpaceJobs.mockResolvedValue([]);
  killSpaceJob.mockResolvedValue({ agent: "alice" });
  fetchSpaceJobLog.mockResolvedValue("");
  useStore.setState({ lobbyJoined: true });
});

describe("SpaceJobsPanel", () => {
  it("says it is waiting before the lobby joins, and loading after — never 'no jobs'", async () => {
    useStore.setState({ lobbyJoined: false });

    render(<SpaceJobsPanel spaceId={7} />);

    expect(
      screen.getByText("Waiting for the lobby connection…"),
    ).toBeInTheDocument();
    expect(refreshSpaceJobs).not.toHaveBeenCalled();

    // The join lands: the visit's read goes out, and until an answer puts a
    // list in the store the panel says it is loading — not that nothing runs.
    act(() => {
      useStore.setState({ lobbyJoined: true });
    });

    await waitFor(() =>
      expect(screen.getByText("Loading shell jobs…")).toBeInTheDocument(),
    );
    expect(refreshSpaceJobs).toHaveBeenCalledWith(7);
    expect(screen.queryByText(/No shell jobs/)).toBeNull();
  });

  it("a failed read with no list is an explicit error with a retry", async () => {
    refreshSpaceJobs.mockRejectedValue({ reason: "forbidden" });

    render(<SpaceJobsPanel spaceId={7} />);

    await waitFor(() =>
      expect(
        screen.getByText(/Shell jobs could not be loaded: forbidden/),
      ).toBeInTheDocument(),
    );

    fireEvent.click(screen.getByRole("button", { name: "Try again" }));
    await waitFor(() => expect(refreshSpaceJobs).toHaveBeenCalledTimes(2));
  });

  it("a known empty space says so, with a refresh", async () => {
    useStore.getState().setSpaceJobs(7, []);

    render(<SpaceJobsPanel spaceId={7} />);

    expect(screen.getByText("Space jobs (0)")).toBeInTheDocument();
    expect(
      screen.getByText("No shell jobs in this space."),
    ).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));
    await waitFor(() => expect(refreshSpaceJobs).toHaveBeenCalledWith(7));
  });

  it("lists every agent's running jobs by name; kill and log act on the space", async () => {
    const bobJob = {
      ...running,
      id: "job-b",
      agent: "bob",
      command: "echo hi",
    };
    useStore.getState().setSpaceJobs(7, [running, bobJob]);
    fetchSpaceJobLog.mockResolvedValue("the output\n");

    render(<SpaceJobsPanel spaceId={7} />);

    expect(screen.getByText("Space jobs (2)")).toBeInTheDocument();
    expect(screen.getByText("alice")).toBeInTheDocument();
    expect(screen.getByText("bob")).toBeInTheDocument();
    expect(screen.getByText("sleep 30")).toBeInTheDocument();
    expect(screen.getByText("echo hi")).toBeInTheDocument();

    fireEvent.click(screen.getAllByRole("button", { name: "Kill" })[0]);
    await waitFor(() => expect(killSpaceJob).toHaveBeenCalledWith(7, "job-a"));

    fireEvent.click(screen.getAllByRole("button", { name: "View log" })[0]);
    await waitFor(() =>
      expect(screen.getByText("the output")).toBeInTheDocument(),
    );
    expect(fetchSpaceJobLog).toHaveBeenCalledWith(7, "job-a");
  });

  it("a namespace-lost update marks the job killed without a reload (#224)", () => {
    useStore.getState().setSpaceJobs(7, [running]);

    render(<SpaceJobsPanel spaceId={7} />);
    expect(screen.getByText("running")).toBeInTheDocument();

    // The frame the manager broadcasts when the space's holder dies: the job
    // is exited, killed by the namespace, at 137. One store replace — the
    // panel re-renders from it like from any other frame.
    act(() => {
      useStore
        .getState()
        .setSpaceJobs(7, [
          { ...running, status: "exited", killed: true, exit_code: 137 },
        ]);
    });

    expect(screen.getByText("Space jobs (0)")).toBeInTheDocument();
    // A finished job is collapsed behind one row (#181), killed ones included:
    // expanding it shows the namespace-lost status like any other exit.
    fireEvent.click(screen.getByRole("button", { name: /1 finished/ }));
    expect(screen.getByText("killed (exit 137)")).toBeInTheDocument();
  });

  it("a failed refresh keeps the list on screen and says so", async () => {
    useStore.getState().setSpaceJobs(7, [running]);

    render(<SpaceJobsPanel spaceId={7} />);
    refreshSpaceJobs.mockRejectedValue(new Error("boom"));

    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));

    await waitFor(() =>
      expect(
        screen.getByText(/Could not refresh shell jobs: boom/),
      ).toBeInTheDocument(),
    );
    // The data is still the server's last word — an error beside it, not
    // instead of it.
    expect(screen.getByText("sleep 30")).toBeInTheDocument();
  });
});
