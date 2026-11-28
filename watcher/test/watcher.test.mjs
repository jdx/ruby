import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { check, cooldownMinutes } from "../src/index.mjs";
import { missingVersions, recipeVersions } from "../src/versions.mjs";

const old = ["v1_9_3_551", "v2_7_8", "v3_1_6", "v3_2_0_rc1", "v3_3_0_preview1"];
const both = ["v3_2_11", "v3_3_13", "v3_4_12", "v4.0.9"];
const current = ["3.2.11", "3.3.13", "3.4.12", "4.0.9"];
const missing = (tags, recipes) => missingVersions(tags, recipes).map((m) => m.version);

// Same cases as test/autobump_check_test.sh, so the watcher and autobump agree.
test("recipes are current", () => {
  assert.deepEqual(missing([...old, ...both], current), []);
});
test("new stable, underscore tag", () => {
  assert.deepEqual(missing([...old, ...both, "v3_4_13"], current), ["3.4.13"]);
});
test("new stable, dotted tag", () => {
  assert.deepEqual(missing([...old, ...both, "v4.0.10"], current), ["4.0.10"]);
});
test("older patch missing, newest present", () => {
  assert.deepEqual(missing(["v3_4_11", "v3_4_12"], ["3.4.12"]), []);
});
test("series older than 3.2 are ignored", () => {
  assert.deepEqual(missing([...old, "v3_1_7", ...both], current), []);
});
test("new prerelease, underscore tag", () => {
  assert.deepEqual(missing([...both, "v4_2_0_preview1"], current), ["4.2.0-preview1"]);
});
test("new prerelease, dotted tag", () => {
  assert.deepEqual(missing([...both, "v4.2.0-preview1"], current), ["4.2.0-preview1"]);
});
test("new rc, underscore tag", () => {
  assert.deepEqual(missing([...both, "v4_2_0_rc1"], current), ["4.2.0-rc1"]);
});
test("recorded prerelease", () => {
  assert.deepEqual(
    missing([...both, "v4_2_0_preview1", "v4.3.0-preview2"], [...current, "4.2.0-preview1", "4.3.0-preview2"]),
    [],
  );
});
test("prerelease in a series that has a stable release", () => {
  assert.deepEqual(missing([...both, "v3_4_0_rc1", "v3_4_0_preview1", "v4.0.0-preview3"], current), []);
});
test("patch versions compare numerically", () => {
  assert.deepEqual(missing(["v4.0.9", "v4.0.10"], ["4.0.9"]), ["4.0.10"]);
});

test("reads every version from the real recipes file", () => {
  const yaml = readFileSync(new URL("../../recipes/rubies.yml", import.meta.url), "utf8");
  const versions = recipeVersions(yaml);
  assert.ok(versions.includes("3.2.1"));
  assert.ok(versions.includes("4.1.0-preview1"));
  assert.equal(versions.length, (yaml.match(/^ {4}sha256:/gm) ?? []).length);
});
test("reads quoted keys and ignores other sections", () => {
  const yaml = "schema: 1\nrubies:\n  '3.4.1':\n    series: x\n  \"4.0.0\":\n    series: y\nother:\n  9.9.9:\n";
  assert.deepEqual(recipeVersions(yaml), ["3.4.1", "4.0.0"]);
});

test("cooldown backs off as a release ages", () => {
  assert.equal(cooldownMinutes(5), 3);
  assert.equal(cooldownMinutes(300), 30);
  assert.equal(cooldownMinutes(2000), null);
});

// check() against a stubbed GitHub API.
const NOW = Date.parse("2026-12-25T03:30:00Z");
const recipesYaml = `rubies:\n${current.map((v) => `  ${v}:\n    series: x\n`).join("")}`;

function stubGitHub({ releases, runs }) {
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const path = new URL(url).pathname;
    calls.push(`${init.method ?? "GET"} ${path}`);
    if (path === "/repos/ruby/ruby/releases") return Response.json(releases);
    if (path === "/repos/jdx/ruby/contents/recipes/rubies.yml") return new Response(recipesYaml);
    if (path.endsWith("/runs")) return Response.json({ workflow_runs: runs });
    if (path.endsWith("/dispatches")) {
      assert.deepEqual(JSON.parse(init.body), { ref: "main", inputs: { rubies_only: "true" } });
      return new Response(null, { status: 204 });
    }
    throw new Error(`unexpected ${path}`);
  };
  return calls;
}
const env = { REPO: "jdx/ruby", GITHUB_TOKEN: "t" };
const release = (tag, minutesAgo) => ({
  tag_name: tag,
  draft: false,
  published_at: new Date(NOW - minutesAgo * 60000).toISOString(),
});
const run = (status, minutesAgo) => ({
  status,
  created_at: new Date(NOW - minutesAgo * 60000).toISOString(),
  html_url: "https://github.com/jdx/ruby/actions/runs/1",
});
const upToDate = both.map((t) => release(t, 60 * 24 * 30));

test("does nothing when the recipes are current", async () => {
  const calls = stubGitHub({ releases: upToDate, runs: [] });
  assert.equal((await check(env, NOW)).action, "none");
  assert.ok(!calls.some((c) => c.includes("/runs") || c.includes("dispatches")));
});
test("dispatches autobump for a fresh release", async () => {
  const calls = stubGitHub({ releases: [release("v4.1.0", 1), ...upToDate], runs: [run("completed", 50)] });
  assert.deepEqual(await check(env, NOW), { action: "dispatched", versions: ["4.1.0"] });
  assert.ok(calls.includes("POST /repos/jdx/ruby/actions/workflows/autobump.yml/dispatches"));
});
test("waits while autobump is already running", async () => {
  stubGitHub({ releases: [release("v4.1.0", 1), ...upToDate], runs: [run("in_progress", 1)] });
  assert.equal((await check(env, NOW)).action, "running");
});
test("sees an older run still working under a cancelled one", async () => {
  stubGitHub({
    releases: [release("v4.1.0", 1), ...upToDate],
    runs: [run("completed", 1), run("in_progress", 4)],
  });
  assert.equal((await check(env, NOW)).action, "running");
});
test("waits out the cooldown after a recent run", async () => {
  stubGitHub({ releases: [release("v4.1.0", 10), ...upToDate], runs: [run("completed", 2)] });
  assert.equal((await check(env, NOW)).action, "cooldown");
});
test("leaves releases older than a day to the hourly cron", async () => {
  const calls = stubGitHub({ releases: [release("v4.1.0", 60 * 25), ...upToDate], runs: [] });
  assert.equal((await check(env, NOW)).action, "stale");
  assert.ok(!calls.some((c) => c.includes("dispatches")));
});
