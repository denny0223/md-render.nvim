const titles = {
  Tests: "Scheduled tests failed",
  Terminal: "Scheduled terminal test failed",
  "Media tools": "Scheduled media-tool test failed",
};
const start = "<!-- md-render-ci-report:start -->";
const end = "<!-- md-render-ci-report:end -->";

async function ensureToolchainLabel(github, repo) {
  const label = { ...repo, name: "toolchain" };
  try {
    await github.rest.issues.getLabel(label);
  } catch (error) {
    if (error.status !== 404) throw error;
    try {
      await github.rest.issues.createLabel({ ...label, color: "5319e7" });
    } catch (error) {
      if (error.status !== 422) throw error;
      await github.rest.issues.getLabel(label);
    }
  }
}

module.exports = async function report({ github, context, core, needs, dryRun = true, now = new Date() }) {
  const attempt = Number(context.runAttempt || process.env.GITHUB_RUN_ATTEMPT || 1);
  const runNumber = Number(context.runNumber || process.env.GITHUB_RUN_NUMBER);
  const observation = context.eventName === "schedule" ||
    (context.eventName === "workflow_dispatch" && context.payload.inputs?.suite === "observation");
  const required = Object.entries(needs).filter(([id]) => observation || id !== "rawhide");
  let passed = required.length > 0 && required.every(([, job]) => job.result === "success");
  let incomplete = required.some(([, job]) => !["success", "failure"].includes(job.result));
  const url = context.serverUrl + "/" + context.repo.owner + "/" + context.repo.repo +
    "/actions/runs/" + context.runId + "/attempts/" + attempt;
  let failed = required.filter(([, job]) => job.result !== "success").map(([id]) => id);

  if (observation) {
    const jobs = await github.paginate(github.rest.actions.listJobsForWorkflowRun, {
      ...context.repo, run_id: context.runId, filter: "latest", per_page: 100,
    });
    const executions = jobs.filter(job =>
      !["Report weekly observation", "Preview CI report"].includes(job.name)
    );
    if (!executions.length || executions.some(job =>
      ["timed_out", "cancelled"].includes(job.conclusion) ||
      (job.status && job.status !== "completed")
    )) incomplete = true;
    if (executions.some(job => job.conclusion !== "success")) passed = false;
    const details = executions.filter(job => job.conclusion !== "success").map(job => {
      const steps = (job.steps || []).filter(step =>
        ["failure", "cancelled", "timed_out"].includes(step.conclusion)
      ).map(step => step.name);
      return job.name + (steps.length ? " / " + steps.join(", ") : " / " + (job.conclusion || job.status));
    });
    if (details.length) failed = details;
  }
  passed = passed && !incomplete;
  if (!passed && !failed.length) failed.push("Required execution metadata is missing or incomplete");
  const status = passed ? "success" : incomplete ? "incomplete" : "failure";
  const writable = !dryRun && observation && context.ref === "refs/heads/main" && attempt === 1 &&
    !(passed && context.eventName !== "schedule");
  failed.sort();
  await core.summary.addHeading("CI result").addRaw(
    "Result: **" + status + "**; attempt " + attempt + ". [Evidence](" + url + ")\n\n" +
    (failed.length ? failed.map(name => "- " + name).join("\n") : "All required jobs completed successfully.") +
    "\n\nNotification: " + (writable ? "main observation" : "read-only preview") + ".\n"
  ).write();

  // A retry or manual green is evidence, not scheduled recovery.
  if (!writable) {
    core.info("Read-only CI report: " + JSON.stringify({ status, failed, url }));
    return { status, changed: false, writable: false };
  }
  const title = titles[context.workflow];
  if (!title) throw new Error("Unknown observation workflow: " + context.workflow);
  if (context.workflow === "Tests" && context.eventName === "schedule") {
    try {
      const month = now.toISOString().slice(0, 7);
      const maintenanceTitle = "CI maintenance: " + month;
      const history = await github.paginate(github.rest.issues.listForRepo, {
        ...context.repo, state: "all", creator: "github-actions[bot]", per_page: 100,
      });
      if (!history.some(issue => !issue.pull_request && issue.title === maintenanceTitle)) {
        const quarter = month.slice(0, 5) + String(Math.floor(now.getUTCMonth() / 3) * 3 + 1).padStart(2, "0");
        const quarterly = !history.some(issue => !issue.pull_request &&
          /^CI maintenance: \d{4}-\d{2}$/.test(issue.title) &&
          issue.title >= "CI maintenance: " + quarter && issue.title < maintenanceTitle);
        const repoUrl = context.serverUrl + "/" + context.repo.owner + "/" + context.repo.repo;
        await ensureToolchainLabel(github, context.repo);
        await github.rest.issues.create({
          ...context.repo, title: maintenanceTitle, labels: ["toolchain"], assignees: [context.repo.owner],
          body: "- [ ] Review fixed CI baselines using [Updating baselines](" + repoUrl +
            "/blob/main/tests/README.md#updating-baselines).\n" +
            (quarterly ? "- [ ] Review minimum supported versions for this quarter.\n" : "") +
            "- [ ] Record **keep**, **update** or **defer**, with evidence and any upgrade PR.\n" +
            "- [ ] Close this issue manually after recording the decisions.\n\n" +
            "This scheduled Tests observation: **" + status + "**. [Evidence](" + url + ")\n\n" +
            "Check [Tests](" + repoUrl + "/actions/workflows/test.yml), [Media](" + repoUrl +
            "/actions/workflows/media.yml) and [Terminal](" + repoUrl + "/actions/workflows/terminal.yml). " +
            "Media and Terminal may still be running; confirm their outcomes separately.\n\n" +
            "Version changes and merges remain manual.\n",
        });
      }
    } catch (error) {
      core.setFailed("Monthly CI maintenance reminder failed: " + error.message);
    }
  }
  const issues = await github.paginate(github.rest.issues.listForRepo, {
    ...context.repo, state: "open", labels: "toolchain", per_page: 100,
  });
  const existing = issues.find(issue => !issue.pull_request && issue.title === title);
  if (passed && !existing) return { status, changed: false, writable: true };
  const match = existing?.body?.match(/<!-- md-render-ci-state: ([A-Za-z0-9+/=]+) -->/);
  let previous;
  if (match) {
    try { previous = JSON.parse(Buffer.from(match[1], "base64").toString("utf8")); }
    catch { core.warning("Existing CI state is unreadable; preserving the issue text."); }
  }
  if (Number.isSafeInteger(previous?.runNumber) && previous.runNumber > runNumber) {
    core.info("Ignoring older observation run " + runNumber + "; issue already reports run " + previous.runNumber + ".");
    return { status, changed: false, writable: true };
  }
  const signature = JSON.stringify(failed);
  const state = {
    status, signature, runNumber,
    firstFailure: !passed && previous?.status === "success" ? url : previous?.firstFailure || url,
  };
  const managed = start + "\nLatest reported observation: **" + status + "**\n\n" +
    "[First failure](" + state.firstFailure + ") · [Latest reported run](" + url + ")\n\n" +
    (failed.length ? failed.map(name => "- " + name).join("\n") :
      "A first-attempt scheduled run completed successfully. Maintainer review is required to close this issue.") +
    "\n\nKeep maintainer classification outside this managed report; an unclassified failure remains unknown.\n" +
    "<!-- md-render-ci-state: " + Buffer.from(JSON.stringify(state)).toString("base64") + " -->\n" + end;
  if (!existing) {
    await ensureToolchainLabel(github, context.repo);
    await github.rest.issues.create({
      ...context.repo, title, labels: ["toolchain"],
      body: managed + "\n\nMaintainer classification: unknown. Edit this text outside the managed report.\n",
    });
    return { status, changed: true, writable: true };
  }
  const original = existing.body || "";
  const body = original.includes(start) && original.includes(end) ?
    original.replace(/<!-- md-render-ci-report:start -->[\s\S]*?<!-- md-render-ci-report:end -->/, managed) :
    original + "\n\n" + managed;
  const changed = !previous || previous.status !== status || previous.signature !== signature;
  if (changed) {
    await github.rest.issues.createComment({
      ...context.repo, issue_number: existing.number,
      body: (passed ? "Scheduled recovery evidence" : "New or changed observation failure") +
        ": " + url + "\n\nClassification and closure remain manual.",
    });
  }
  await github.rest.issues.update({ ...context.repo, issue_number: existing.number, body });
  return { status, changed, writable: true };
};
