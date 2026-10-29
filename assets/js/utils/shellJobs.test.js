/**
 * The running/finished split (#181): the jobs tab counts one side and the
 * panel renders both, so the definitions live in one place and are tested on
 * their own.
 */
import { describe, it, expect } from "vitest";
import {
  finishedJobs,
  isRunning,
  runningJobCount,
  runningJobs,
} from "./shellJobs";

const jobs = [
  { id: "job-1", status: "running" },
  { id: "job-2", status: "exited" },
  { id: "job-3", status: "running" },
];

describe("shellJobs", () => {
  it("splits a list into the live jobs and the finished ones", () => {
    expect(runningJobs(jobs).map((job) => job.id)).toEqual(["job-1", "job-3"]);
    expect(finishedJobs(jobs).map((job) => job.id)).toEqual(["job-2"]);
    expect(jobs.map(isRunning)).toEqual([true, false, true]);
    // The count is the live side's length — the sidebar badge's number for the
    // same state.
    expect(runningJobCount(jobs)).toBe(2);
  });
});
