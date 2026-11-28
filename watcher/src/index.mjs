// Cloudflare Worker that watches for new Ruby releases every minute and
// dispatches jdx/ruby's autobump workflow as soon as one appears.
//
// GitHub's own scheduled runs are too unreliable for this: the hourly autobump
// cron fires only every few hours. Autobump stays the one place that writes
// recipes; this worker only decides when to start it.

import { missingVersions, recipeVersions } from "./versions.mjs";

const UPSTREAM = "ruby/ruby";
const WORKFLOW = "autobump.yml";

// How long to wait after the last autobump run before dispatching again, by
// how long ago the missing release was published. A fresh release is retried
// often, since its tarball can reach cache.ruby-lang.org a little after the
// GitHub release; an older one backs off so a release autobump can't add
// doesn't start a run every few minutes forever. Past a day, the hourly cron
// and its failure email take over.
export function cooldownMinutes(ageMinutes) {
  if (ageMinutes < 120) return 3;
  if (ageMinutes < 24 * 60) return 30;
  return null;
}

async function github(env, path, init = {}) {
  const res = await fetch(`https://api.github.com${path}`, {
    ...init,
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${env.GITHUB_TOKEN}`,
      "user-agent": "jdx-ruby-release-watcher",
      "x-github-api-version": "2022-11-28",
      ...init.headers,
    },
  });
  if (!res.ok) {
    throw new Error(`GitHub ${init.method ?? "GET"} ${path}: ${res.status} ${await res.text()}`);
  }
  return res;
}

export async function check(env, now = Date.now()) {
  const repo = env.REPO;
  const [releases, recipes] = await Promise.all([
    github(env, `/repos/${UPSTREAM}/releases?per_page=100`).then((r) => r.json()),
    github(env, `/repos/${repo}/contents/recipes/rubies.yml?ref=main`, {
      headers: { accept: "application/vnd.github.raw+json" },
    }).then((r) => r.text()),
  ]);

  const tags = releases.filter((r) => !r.draft).map((r) => r.tag_name);
  const missing = missingVersions(tags, recipeVersions(recipes));
  if (missing.length === 0) return { action: "none" };

  const published = new Map(releases.map((r) => [r.tag_name, Date.parse(r.published_at)]));
  const cooldowns = missing
    .map((m) => cooldownMinutes((now - published.get(m.tag)) / 60000))
    .filter((c) => c !== null);
  const versions = missing.map((m) => m.version);
  if (cooldowns.length === 0) return { action: "stale", versions };
  const cooldown = Math.min(...cooldowns);

  // Newest first. Look past the newest run: a queued run that concurrency
  // cancelled can sit on top while an older one is still working.
  const { workflow_runs: runs } = await github(
    env,
    `/repos/${repo}/actions/workflows/${WORKFLOW}/runs?per_page=20`,
  ).then((r) => r.json());
  const active = runs.find((r) => r.status !== "completed");
  if (active) {
    return { action: "running", versions, run: active.html_url };
  }
  const last = runs[0];
  if (last && now - Date.parse(last.created_at) < cooldown * 60000) {
    return { action: "cooldown", versions, run: last.html_url };
  }

  await github(env, `/repos/${repo}/actions/workflows/${WORKFLOW}/dispatches`, {
    method: "POST",
    body: JSON.stringify({ ref: "main", inputs: { rubies_only: "true" } }),
  });
  return { action: "dispatched", versions };
}

export default {
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(
      check(env).then((result) => console.log(JSON.stringify(result))),
    );
  },
};
