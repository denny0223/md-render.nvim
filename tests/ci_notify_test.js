const test = require("node:test");
const assert = require("node:assert/strict");
const report = require("../.github/ci/notify.js");

function fixture(overrides = {}) {
  const writes = [];
  const summary = { addHeading() { return this; }, addRaw() { return this; }, async write() {} };
  const context = {
    repo: { owner: "example", repo: "plugin" }, serverUrl: "https://github.com",
    workflow: "Terminal", eventName: "schedule", ref: "refs/heads/main",
    runId: 20, runAttempt: 1, payload: {}, ...overrides.context,
  };
  const actions = { listJobsForWorkflowRun() {} };
  const issues = {
    listForRepo() {},
    async create(value) { writes.push(["create", value]); },
    async update(value) { writes.push(["update", value]); },
    async createComment(value) { writes.push(["comment", value]); },
  };
  const github = {
    rest: { actions, issues },
    async paginate(method) {
      return method === actions.listJobsForWorkflowRun ? (overrides.jobs || [{
        name: "kitty-matrix", status: "completed",
        conclusion: overrides.needs?.["kitty-matrix"]?.result || "failure", steps: [],
      }]) : (overrides.issues || []);
    },
  };
  const args = {
    github, context, core: { summary, info() {}, warning() {} },
    needs: { "kitty-matrix": { result: "failure" } }, dryRun: false, ...overrides,
  };
  args.context = context;
  return { args, writes };
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
});

test("persistent failure updates evidence without another classification task", async () => {
  const issue = existing({ status: "failure", signature: '["kitty-matrix / failure"]', firstFailure: "https://first" });
  for (const runId of [20, 21, 22]) {
    const { args, writes } = fixture({ issues: [issue], context: { runId } });
    assert.equal((await report(args)).changed, false);
    assert.deepEqual(writes.map(([kind]) => kind), ["update"]);
    assert.match(writes[0][1].body, /Maintainer classification: upstream issue/);
    assert.match(writes[0][1].body, /https:\/\/first/);
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
  assert.deepEqual(writes.map(([kind]) => kind), ["update", "comment"]);
  assert.match(writes[1][1].body, /New or changed/);
});

test("scheduled recovery links evidence and never closes the issue", async () => {
  const issue = existing({ status: "failure", signature: '["kitty-matrix"]', firstFailure: "https://first" });
  const { args, writes } = fixture({ issues: [issue], needs: { "kitty-matrix": { result: "success" } } });
  assert.equal((await report(args)).status, "success");
  assert.deepEqual(writes.map(([kind]) => kind), ["update", "comment"]);
  assert.match(writes[1][1].body, /Scheduled recovery evidence/);
  assert.equal(writes[0][1].state, undefined);
});

test("a manual green cannot replace scheduled recovery evidence", async () => {
  const { args, writes } = fixture({
    context: { eventName: "workflow_dispatch", payload: { inputs: { suite: "observation" } } },
    needs: { "kitty-matrix": { result: "success" } },
  });
  assert.equal((await report(args)).writable, false);
  assert.deepEqual(writes, []);
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
      issues: [issue], context: { runId },
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
    assert.deepEqual(writes.map(([kind]) => kind), changed ? ["update", "comment"] : ["update"]);
    assert.ok(writes[0][1].body.includes("minimum / Require original phases / " + phases));
    assert.match(writes[0][1].body, /Maintainer classification: upstream issue/);
    issue.body = writes[0][1].body;
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
    assert.equal(writes[0][0], issues.length ? "update" : "create");
    assert.match(writes[0][1].body, /missing or incomplete/);
    assert.doesNotMatch(writes[0][1].body, /completed successfully/);
    for (const [, value] of writes) assert.doesNotMatch(value.body, /Scheduled recovery evidence/);
  }
});
