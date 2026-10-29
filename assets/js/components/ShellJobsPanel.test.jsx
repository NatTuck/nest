/**
 * ShellJobsPanel component tests.
 *
 * Covers: rendering nothing with no jobs, rendering the running job rows, the
 * finished jobs collapsed behind one row (#181), the kill action, and the log
 * viewer (loading, content, and error states).
 */
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import { ShellJobsPanel } from "./ShellJobsPanel";

const runningJob = {
  id: "job-1",
  command: "sleep 30",
  status: "running",
  exit_code: null,
  killed: false,
  log_path: "/tmp/shell-jobs/job-1.log",
};

const finishedJob = {
  ...runningJob,
  id: "job-2",
  command: "echo done",
  status: "exited",
  exit_code: 0,
};

describe("ShellJobsPanel", () => {
  it("renders nothing when there are no jobs", () => {
    const { container } = render(
      <ShellJobsPanel jobs={[]} onKill={() => {}} onOpenLog={() => {}} />,
    );

    expect(container.firstChild).toBeNull();
  });

  it("renders a running job with its command", () => {
    render(
      <ShellJobsPanel
        jobs={[runningJob]}
        onKill={() => {}}
        onOpenLog={() => {}}
      />,
    );

    expect(screen.getByText("Shell jobs (1)")).toBeInTheDocument();
    expect(screen.getByText("running")).toBeInTheDocument();
    expect(screen.getByText("sleep 30")).toBeInTheDocument();
    expect(screen.getByText("job-1")).toBeInTheDocument();
  });

  it("hides the title but keeps Refresh when embedded in a tab", () => {
    render(
      <ShellJobsPanel
        jobs={[runningJob]}
        onKill={() => {}}
        onOpenLog={() => {}}
        showTitle={false}
      />,
    );

    expect(screen.queryByText("Shell jobs (1)")).toBeNull();
    expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument();
    expect(screen.getByText("sleep 30")).toBeInTheDocument();
  });

  it("calls onKill for a running job", () => {
    const onKill = vi.fn();

    render(
      <ShellJobsPanel
        jobs={[runningJob]}
        onKill={onKill}
        onOpenLog={() => {}}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Kill" }));
    expect(onKill).toHaveBeenCalledWith("job-1");
  });

  it("collapses the finished jobs, counting only the running ones (#181)", () => {
    // Finished jobs first in the array: the panel's own split is what puts the
    // running rows on top, not the order the server handed it.
    const finished = [
      finishedJob,
      { ...finishedJob, id: "job-3", command: "echo two" },
      { ...finishedJob, id: "job-4", command: "echo three", killed: true },
    ];

    render(
      <ShellJobsPanel
        jobs={[...finished, runningJob]}
        onKill={() => {}}
        onOpenLog={() => {}}
      />,
    );

    // The title counts what is live, like the jobs tab's label does.
    expect(screen.getByText("Shell jobs (1)")).toBeInTheDocument();
    expect(screen.getByText("sleep 30")).toBeInTheDocument();

    // Finished jobs are not the first thing read: one collapsed row stands in
    // for them, and nothing is hidden permanently.
    expect(screen.queryByText("echo done")).toBeNull();
    expect(screen.queryByText("exited 0")).toBeNull();
    expect(screen.getByRole("button", { name: /3 finished/ })).toHaveAttribute(
      "aria-expanded",
      "false",
    );

    // The running row comes before the collapsed row.
    const rows = screen.getAllByRole("listitem").map((li) => li.textContent);
    expect(rows[0]).toContain("sleep 30");
    expect(rows[1]).toContain("3 finished");
  });

  it("expands the finished jobs to the same rows", () => {
    render(
      <ShellJobsPanel
        jobs={[runningJob, finishedJob]}
        onKill={() => {}}
        onOpenLog={() => {}}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /1 finished/ }));

    expect(screen.getByRole("button", { name: /1 finished/ })).toHaveAttribute(
      "aria-expanded",
      "true",
    );
    expect(screen.getByText("echo done")).toBeInTheDocument();
    expect(screen.getByText("exited 0")).toBeInTheDocument();
    // The finished row is a row like any other — except that it cannot be
    // killed, so the only Kill on screen is the running job's.
    expect(screen.getAllByRole("button", { name: "Kill" })).toHaveLength(1);
  });

  it("does not offer Kill for a finished job", () => {
    render(
      <ShellJobsPanel
        jobs={[finishedJob]}
        onKill={() => {}}
        onOpenLog={() => {}}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: /1 finished/ }));

    expect(screen.queryByRole("button", { name: "Kill" })).toBeNull();
    expect(screen.getByText("exited 0")).toBeInTheDocument();
  });

  it("loads and shows the job log on demand", async () => {
    const onOpenLog = vi.fn().mockResolvedValue("hello output\n");

    render(
      <ShellJobsPanel
        jobs={[finishedJob]}
        onKill={() => {}}
        onOpenLog={onOpenLog}
      />,
    );

    // A finished job's log is still reachable: expand the collapsed group, then
    // open the row's log like any other.
    fireEvent.click(screen.getByRole("button", { name: /1 finished/ }));
    fireEvent.click(screen.getByRole("button", { name: "View log" }));

    await waitFor(() =>
      expect(screen.getByText("hello output")).toBeInTheDocument(),
    );
    expect(onOpenLog).toHaveBeenCalledWith("job-2");
  });

  it("shows an error when the log fetch fails", async () => {
    const onOpenLog = vi.fn().mockRejectedValue(new Error("boom"));

    render(
      <ShellJobsPanel
        jobs={[runningJob]}
        onKill={() => {}}
        onOpenLog={onOpenLog}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "View log" }));

    await waitFor(() => expect(screen.getByText("boom")).toBeInTheDocument());
  });

  it("shows an error when a kill fails", async () => {
    const onKill = vi.fn().mockRejectedValue(new Error("kaboom"));

    render(
      <ShellJobsPanel
        jobs={[runningJob]}
        onKill={onKill}
        onOpenLog={() => {}}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Kill" }));

    await waitFor(() => expect(screen.getByText("kaboom")).toBeInTheDocument());
  });

  it("calls onRefresh and surfaces its failure", async () => {
    const onRefresh = vi.fn().mockRejectedValue(new Error("nope"));

    render(
      <ShellJobsPanel
        jobs={[runningJob]}
        onKill={() => {}}
        onOpenLog={() => {}}
        onRefresh={onRefresh}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "Refresh" }));

    await waitFor(() => expect(screen.getByText("nope")).toBeInTheDocument());
    expect(onRefresh).toHaveBeenCalled();
  });

  it("clears the open log when its job disappears", async () => {
    const onOpenLog = vi.fn().mockResolvedValue("hello output\n");
    const jobA = { ...runningJob, id: "job-a" };
    const jobB = { ...runningJob, id: "job-b" };

    const { rerender } = render(
      <ShellJobsPanel jobs={[jobA]} onKill={() => {}} onOpenLog={onOpenLog} />,
    );

    fireEvent.click(screen.getByRole("button", { name: "View log" }));
    await waitFor(() =>
      expect(screen.getByText("hello output")).toBeInTheDocument(),
    );

    // job-a is gone; then job-a returns. The stale viewer must not reopen.
    rerender(
      <ShellJobsPanel jobs={[jobB]} onKill={() => {}} onOpenLog={onOpenLog} />,
    );
    rerender(
      <ShellJobsPanel jobs={[jobA]} onKill={() => {}} onOpenLog={onOpenLog} />,
    );

    expect(screen.queryByText("hello output")).toBeNull();
    expect(
      screen.getByRole("button", { name: "View log" }),
    ).toBeInTheDocument();
  });
});
