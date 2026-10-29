/**
 * The running/finished split of an agent's shell jobs (#181).
 *
 * The server ships the whole list — a finished job is kept so `shell-wait` can
 * still answer for it, and the log viewer can still read it — but only a
 * running job is *live*. Everything that counts or lists jobs reads the split
 * from here, so the tab's number and the panel's collapsed row cannot disagree
 * about what "running" means, and neither can drift from the sidebar badge
 * (whose number the server computes the same way, `Info.running_count/1`).
 */

/** Whether `job` is still running. */
export function isRunning(job) {
  return job.status === "running";
}

/** The live jobs: what the tab counts and the panel lists first. */
export function runningJobs(jobs) {
  return jobs.filter(isRunning);
}

/** The finished jobs: still retrievable by id, collapsed behind one row. */
export function finishedJobs(jobs) {
  return jobs.filter((job) => !isRunning(job));
}

/** How many jobs are live. */
export function runningJobCount(jobs) {
  return runningJobs(jobs).length;
}
