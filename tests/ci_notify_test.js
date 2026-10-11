const test = require("node:test");
const assert = require("node:assert/strict");
const report = require("../.github/ci/notify.js");

function fixture(overrides = {}) {
  const writes = [];
  const reads = [];
  const summaries = [];
  const failures = [];
  const summary = {
    addHeading() { return this; }, addRaw(value) { summaries.push(value); return this; }, async write() {},
  };
  const needs = overrides.needs || { "kitty-matrix": { result: "failure" } };
  const context = {
    repo: { owner: "example", repo: "plugin" }, serverUrl: "https://github.com",
    workflow: "Terminal", eventName: "schedule", ref: "refs/heads/main",
    runId: 20, runNumber: 20, runAttempt: 1, payload: {}, ...overrides.context,
  };
  const actions = { listJobsForWorkflowRun() {} };
  const issues = {
    listForRepo() {},
    async getLabel(value) { reads.push(["label", value]); },
    async createLabel(value) { writes.push(["label", value]); },
    async create(value) { writes.push(["create", value]); },
    async update(value) { writes.push(["update", value]); },
    async createComment(value) { writes.push(["comment", value]); },
  };
  const github = {
    rest: { actions, issues },
    async paginate(method, value) {
      reads.push([method === actions.listJobsForWorkflowRun ? "jobs" : "issues", value]);
      return method === actions.listJobsForWorkflowRun ?
        (overrides.jobs || Object.entries(needs).map(([name, job]) => ({
          name, status: "completed", conclusion: job.result, steps: [],
        }))) : (overrides.issues || []).filter(issue =>
          (!issue.state || value.state === "all" || issue.state === value.state) &&
          (!value.creator || issue.user?.login === value.creator));
    },
  };
  const args = {
    github, context, core: { summary, info() {}, warning() {}, setFailed(value) { failures.push(value); } },
    needs, dryRun: false, now: new Date("2026-10-21T12:00:00Z"), ...overrides,
  };
  args.context = context;
  return { args, writes, reads, summaries, failures };
}

function state(body) {
  return JSON.parse(Buffer.from(body.match(/<!-- md-render-ci-state: (\S+) -->/)[1], "base64"));
}

function existing(state) {
  const marker = Buffer.from(JSON.stringify(state)).toString("base64");
  return {
    number: 9, title: "Scheduled terminal test failed",
    body: "Maintainer classification: upstream issue.\n<!-- md-render-ci-report:start -->\n" +
      "<!-- md-render-ci-state: " + marker + " -->\n<!-- md-render-ci-report:end -->",
  };
}

test("preview, PR, branch, baseline and retries cannot mutate issues", async () => {
  const contexts = [
    { ref: "refs/heads/test/ci" },
    { eventName: "pull_request", ref: "refs/pull/84/merge" },
    { eventName: "workflow_dispatch", payload: { inputs: { suite: "baseline" } } },
    { runAttempt: 2 },
  ];
  for (const context of contexts) {
    const { args, writes } = fixture({ context });
    assert.equal((await report(args)).writable, false);
    assert.deepEqual(writes, []);
  }
  const { args, writes } = fixture({ dryRun: true });
  await report(args);
  assert.deepEqual(writes, []);
});

test("first failure creates one issue and does not guess its cause", async () => {
  const { args, writes } = fixture();
  assert.equal((await report(args)).status, "failure");
  assert.equal(writes.length, 1);
  assert.equal(writes[0][0], "create");
  assert.match(writes[0][1].body, /unclassified failure remains unknown/);
  assert.ok(writes[0][1].body.indexOf('Maintainer classification: unknown.') >
    writes[0][1].body.indexOf('<!-- md-render-ci-report:end -->'));
  assert.equal(state(writes[0][1].body).runNumber, 20);
});

test("persistent failure updates evidence without another classification task", async () => {
  const issue = existing({ status: "failure", signature: '["kitty-matrix / failure"]', firstFailure: "https://first" });
  for (const runId of [20, 21, 22]) {
    const { args, writes } = fixture({ issues: [issue], context: { runId, runNumber: runId } });
    args.github.rest.issues.getLabel = async () => { throw new Error("label service unavailable"); };
    assert.equal((await report(args)).changed, false);
    assert.deepEqual(writes.map(([kind]) => kind), ["update"]);
    assert.match(writes[0][1].body, /Maintainer classification: upstream issue/);
    assert.match(writes[0][1].body, /https:\/\/first/);
    assert.equal(state(writes[0][1].body).runNumber, runId);
    issue.body = writes[0][1].body;
  }
});

test("changed failure is visible and incomplete is never green", async () => {
  const issue = existing({ status: "failure", signature: '["old-check"]' });
  const { args, writes } = fixture({
    issues: [issue], needs: { "kitty-matrix": { result: "cancelled" } },
    jobs: [{ name: "minimum / images", conclusion: "cancelled", steps: [] }],
  });
  assert.equal((await report(args)).status, "incomplete");
  assert.deepEqual(writes.map(([kind]) => kind), ["comment", "update"]);
  assert.match(writes[0][1].body, /New or changed/);
});

test("scheduled recovery links evidence and never closes the issue", async () => {
  const issue = existing({ status: "failure", signature: '["kitty-matrix"]', firstFailure: "https://first" });
  const { args, writes } = fixture({ issues: [issue], needs: { "kitty-matrix": { result: "success" } } });
  assert.equal((await report(args)).status, "success");
  assert.deepEqual(writes.map(([kind]) => kind), ["comment", "update"]);
  assert.match(writes[0][1].body, /Scheduled recovery evidence/);
  assert.equal(writes[1][1].state, undefined);
});

test("a manual green cannot replace scheduled recovery evidence", async () => {
  const { args, writes, summaries } = fixture({
    context: { eventName: "workflow_dispatch", payload: { inputs: { suite: "observation" } } },
    needs: { "kitty-matrix": { result: "success" } },
  });
  assert.equal((await report(args)).writable, false);
  assert.deepEqual(writes, []);
  assert.match(summaries[0], /Notification: read-only preview/);
  assert.doesNotMatch(summaries[0], /Notification: main observation/);
});

test("green without an existing issue does not announce every weekly run", async () => {
  const { args, writes } = fixture({ needs: { "kitty-matrix": { result: "success" } } });
  await report(args);
  assert.deepEqual(writes, []);
});

test("notifier jobs are excluded from the failure signature", async () => {
  const { args, writes } = fixture({
    jobs: [
      { name: "minimum", conclusion: "failure", steps: [{ name: "Image pixels", conclusion: "failure" }] },
      { name: "Report weekly observation", conclusion: null, status: "in_progress" },
      { name: "Preview CI report", conclusion: "skipped" },
    ],
  });
  await report(args);
  assert.match(writes[0][1].body, /minimum \/ Image pixels/);
  assert.doesNotMatch(writes[0][1].body, /in_progress|Preview CI report/);
});

test("original phase gate distinguishes failures hidden by continue-on-error", async () => {
  const issue = existing({
    status: "failure", signature: '["minimum / Require original phases / native36"]',
    firstFailure: "https://first",
  });
  for (const [runId, phases, changed] of [
    [20, "native36", false],
    [21, "native36,images", true],
    [22, "native36,images", false],
  ]) {
    const { args, writes } = fixture({
      issues: [issue], context: { runId, runNumber: runId },
      jobs: [{
        name: "minimum", status: "completed", conclusion: "failure",
        steps: [
          { name: "Run native headings", conclusion: "success" },
          { name: "Check image pixels", conclusion: "success" },
          { name: "Summarize required phases", conclusion: "success" },
          { name: "Require original phases / " + phases, conclusion: "failure" },
        ],
      }],
    });
    const result = await report(args);
    assert.equal(result.status, "failure");
    assert.equal(result.changed, changed);
    assert.deepEqual(writes.map(([kind]) => kind), changed ? ["comment", "update"] : ["update"]);
    assert.ok(writes.at(-1)[1].body.includes("minimum / Require original phases / " + phases));
    assert.match(writes.at(-1)[1].body, /Maintainer classification: upstream issue/);
    issue.body = writes.at(-1)[1].body;
  }
});

test("whole-job timeout and missing execution metadata are incomplete", async () => {
  for (const jobs of [
    [{ name: "minimum", status: "completed", conclusion: "timed_out", steps: [] }],
    [],
  ]) {
    const { args } = fixture({ jobs });
    assert.equal((await report(args)).status, "incomplete");
  }
});

test("missing metadata with successful needs cannot announce recovery", async () => {
  for (const issues of [[], [existing({ status: "failure", signature: '["kitty-matrix"]' })]]) {
    const { args, writes } = fixture({
      issues, jobs: [], needs: { "kitty-matrix": { result: "success" } },
    });
    assert.equal((await report(args)).status, "incomplete");
    assert.equal(writes.at(-1)[0], issues.length ? "update" : "create");
    assert.match(writes.at(-1)[1].body, /missing or incomplete/);
    assert.doesNotMatch(writes.at(-1)[1].body, /completed successfully/);
    for (const [, value] of writes) assert.doesNotMatch(value.body, /Scheduled recovery evidence/);
  }
});

test("older reported runs cannot overwrite a newer manual failure", async () => {
  const issue = existing({ status: "success", signature: "[]", runNumber: 19 });
  const manual = fixture({
    issues: [issue], context: {
      runNumber: 22, eventName: "workflow_dispatch", payload: { inputs: { suite: "observation" } },
    },
  });
  await report(manual.args);
  issue.body = manual.writes.at(-1)[1].body;
  assert.equal(state(issue.body).runNumber, 22);
  for (const result of ["success", "failure"]) {
    const { args, writes } = fixture({
      issues: [issue], context: { runId: 1000, runNumber: 21 },
      needs: { different: { result } },
    });
    await report(args);
    assert.deepEqual(writes, []);
  }
  const newer = fixture({
    issues: [issue], context: { runNumber: 23 }, needs: { "kitty-matrix": { result: "success" } },
  });
  await report(newer.args);
  assert.match(newer.writes[0][1].body, /Scheduled recovery evidence/);
  assert.equal(state(newer.writes[1][1].body).runNumber, 23);
});

test("run number can come from the Actions environment", async () => {
  const original = process.env.GITHUB_RUN_NUMBER;
  try {
    process.env.GITHUB_RUN_NUMBER = "25";
    const { args, writes } = fixture({ context: { runNumber: undefined } });
    await report(args);
    assert.equal(state(writes[0][1].body).runNumber, 25);
  } finally {
    if (original === undefined) delete process.env.GITHUB_RUN_NUMBER;
    else process.env.GITHUB_RUN_NUMBER = original;
  }
});

test("a failed comment leaves the change pending for the next observation", async () => {
  const issue = existing({ status: "failure", signature: '["old-check"]', runNumber: 19 });
  const { args, writes } = fixture({ issues: [issue] });
  const comment = args.github.rest.issues.createComment;
  args.github.rest.issues.createComment = async () => { throw new Error("comment unavailable"); };
  await assert.rejects(report(args), /comment unavailable/);
  assert.deepEqual(writes, []);
  assert.equal(state(issue.body).runNumber, 19);
  args.github.rest.issues.createComment = comment;
  args.context.runNumber = 21;
  assert.equal((await report(args)).changed, true);
  assert.deepEqual(writes.map(([kind]) => kind), ["comment", "update"]);
  assert.equal(state(writes[1][1].body).runNumber, 21);
});

test("label creation only follows 404 and a 422 race must be verified", async () => {
  for (const [getErrors, createError, error, expected] of [
    [[404], undefined, undefined, ["get", "create", "issue"]],
    [[404, undefined], 422, undefined, ["get", "create", "get", "issue"]],
    [[403], undefined, 403, ["get"]],
    [[500], undefined, 500, ["get"]],
    [[404], 500, 500, ["get", "create"]],
    [[404, 404], 422, 404, ["get", "create", "get"]],
    [[404, 403], 422, 403, ["get", "create", "get"]],
  ]) {
    const { args, writes } = fixture();
    const calls = [];
    const api = args.github.rest.issues;
    api.getLabel = async value => {
      calls.push("get");
      assert.equal(value.name, "toolchain");
      const status = getErrors.shift();
      if (status) throw Object.assign(new Error("label lookup"), { status });
    };
    api.createLabel = async value => {
      calls.push("create");
      assert.equal(value.name, "toolchain");
      if (createError) throw Object.assign(new Error("label creation"), { status: createError });
    };
    const create = api.create;
    api.create = async value => { calls.push("issue"); return create(value); };
    if (error) {
      await assert.rejects(report(args), reason => reason.status === error);
      assert.deepEqual(writes, []);
    } else {
      await report(args);
      assert.deepEqual(writes[0][1].labels, ["toolchain"]);
    }
    assert.deepEqual(calls, expected);
  }
});

test("scheduled Tests create an assigned monthly reminder with green or failed evidence", async () => {
  for (const result of ["success", "failure"]) {
    const { args, writes, reads } = fixture({ context: { workflow: "Tests" }, needs: { core: { result } } });
    await report(args);
    const reminders = writes.filter(([kind, value]) => kind === "create" && value.title === "CI maintenance: 2026-10");
    assert.equal(reminders.length, 1);
    const reminder = reminders[0][1];
    assert.deepEqual(reminder.assignees, ["example"]);
    assert.deepEqual(reminder.labels, ["toolchain"]);
    assert.match(reminder.body, new RegExp("Tests observation: \\*\\*" + result));
    assert.match(reminder.body, /actions\/runs\/20\/attempts\/1/);
    assert.match(reminder.body, /tests\/README.md#updating-baselines/);
    for (const workflow of ["test", "media", "terminal"]) {
      assert.ok(reminder.body.includes("/actions/workflows/" + workflow + ".yml"));
    }
    assert.match(reminder.body, /Media and Terminal may still be running/);
    assert.match(reminder.body, /\*\*keep\*\*.*\*\*update\*\*.*\*\*defer\*\*/);
    assert.match(reminder.body, /Close this issue manually/);
    assert.equal(writes.length, result === "failure" ? 2 : 1);
    assert.ok(reads.some(([kind, value]) => kind === "issues" && value.state === "all" &&
      value.creator === "github-actions[bot]" && !value.labels));
  }
});

test("closed monthly reminders stay closed and the first reminder of each quarter includes support", async () => {
  for (const [month, previous, create, quarterly] of [
    ["2026-10", [], true, true],
    ["2026-10", ["2026-10"], false, false],
    ["2026-11", ["2026-10"], true, false],
    ["2026-11", [], true, true],
    ["2026-12", ["2026-11"], true, false],
    ["2027-01", ["2026-12"], true, true],
  ]) {
    const { args, writes } = fixture({
      context: { workflow: "Tests" }, needs: { core: { result: "success" } },
      now: new Date(month + "-21T12:00:00Z"),
      issues: previous.map(value => ({
        title: "CI maintenance: " + value, state: "closed", user: { login: "github-actions[bot]" },
      })),
    });
    await report(args);
    assert.equal(writes.length, create ? 1 : 0, month);
    if (create) {
      assert.equal(writes[0][1].title, "CI maintenance: " + month);
      assert.equal(writes[0][1].body.includes("minimum supported versions"), quarterly, month);
    }
  }
});

test("only first-attempt scheduled Tests on main can create maintenance reminders", async () => {
  for (const overrides of [
    { context: { workflow: "Terminal" } },
    { context: { workflow: "Media tools" } },
    { context: { ref: "refs/heads/test/ci" } },
    { context: { eventName: "pull_request", ref: "refs/pull/84/merge" } },
    { context: { eventName: "workflow_dispatch", payload: { inputs: { suite: "observation" } } } },
    { context: { eventName: "workflow_dispatch", payload: { inputs: { suite: "baseline" } } } },
    { context: { runAttempt: 2 } },
    { dryRun: true },
  ]) {
    const { args, writes, reads } = fixture({
      ...overrides, context: { workflow: "Tests", ...overrides.context },
    });
    await report(args);
    assert.ok(writes.every(([, value]) => !value.title?.startsWith("CI maintenance:")));
    assert.ok(reads.every(([kind, value]) => kind !== "issues" || value.state !== "all"));
  }
});

test("issues from other users cannot suppress monthly or quarterly reminders", async () => {
  const { args, writes } = fixture({
    context: { workflow: "Tests" }, needs: { core: { result: "success" } },
    now: new Date("2026-11-21T12:00:00Z"),
    issues: ["2026-10", "2026-11"].map(month => ({
      title: "CI maintenance: " + month, state: "closed", user: { login: "contributor" },
    })),
  });
  await report(args);
  assert.equal(writes.length, 1);
  assert.equal(writes[0][1].title, "CI maintenance: 2026-11");
  assert.match(writes[0][1].body, /minimum supported versions/);
});

test("maintenance errors fail the reporter without blocking observation issues", async () => {
  for (const point of ["history", "label", "create"]) {
    for (const result of ["success", "failure"]) {
      const { args, writes, failures } = fixture({ context: { workflow: "Tests" }, needs: { core: { result } } });
      if (point === "history") {
        const paginate = args.github.paginate;
        args.github.paginate = async (method, value) => {
          if (value.state === "all") throw new Error("history unavailable");
          return paginate(method, value);
        };
      } else if (point === "label") {
        const getLabel = args.github.rest.issues.getLabel;
        args.github.rest.issues.getLabel = async value => {
          args.github.rest.issues.getLabel = getLabel;
          throw new Error("label unavailable");
        };
      } else {
        const create = args.github.rest.issues.create;
        args.github.rest.issues.create = async value => {
          if (value.title.startsWith("CI maintenance:")) throw new Error("create unavailable");
          return create(value);
        };
      }
      assert.equal((await report(args)).status, result);
      assert.deepEqual(failures, ["Monthly CI maintenance reminder failed: " + point + " unavailable"]);
      assert.equal(writes.length, result === "failure" ? 1 : 0);
      if (result === "failure") assert.equal(writes[0][1].title, "Scheduled tests failed");
    }
  }
});
