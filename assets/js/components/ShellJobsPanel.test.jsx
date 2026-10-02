/**
 * ShellJobsPanel component tests.
 *
 * Covers: rendering nothing with no jobs, rendering job rows, the kill
 * action, and the log viewer (loading, content, and error states).
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

    expect(screen.getByText("Background jobs (1)")).toBeInTheDocument();
    expect(screen.getByText("running")).toBeInTheDocument();
    expect(screen.getByText("sleep 30")).toBeInTheDocument();
    expect(screen.getByText("job-1")).toBeInTheDocument();
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

  it("does not offer Kill for a finished job", () => {
    render(
      <ShellJobsPanel
        jobs={[{ ...runningJob, status: "exited", exit_code: 0 }]}
        onKill={() => {}}
        onOpenLog={() => {}}
      />,
    );

    expect(screen.queryByRole("button", { name: "Kill" })).toBeNull();
    expect(screen.getByText("exited 0")).toBeInTheDocument();
  });

  it("loads and shows the job log on demand", async () => {
    const onOpenLog = vi.fn().mockResolvedValue("hello output\n");

    render(
      <ShellJobsPanel
        jobs={[{ ...runningJob, status: "exited", exit_code: 0 }]}
        onKill={() => {}}
        onOpenLog={onOpenLog}
      />,
    );

    fireEvent.click(screen.getByRole("button", { name: "View log" }));

    await waitFor(() =>
      expect(screen.getByText("hello output")).toBeInTheDocument(),
    );
    expect(onOpenLog).toHaveBeenCalledWith("job-1");
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
