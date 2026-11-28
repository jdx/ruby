// Decides which upstream Ruby releases the autobump workflow would add.
//
// Mirrors the version selection in .github/workflows/autobump.yml so the
// watcher only dispatches autobump when that run would actually add a recipe:
// the newest stable release of every series from 3.2 on, and prereleases of
// series that have no stable release yet.

const PRERELEASE = /(preview|rc)/i;

function supportedSeries(minor) {
  const [major, min] = minor.split(".").map(Number);
  return major > 3 || (major === 3 && min >= 2);
}

function compareVersions(a, b) {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d;
  }
  return 0;
}

// v3_4_13 -> 3.4.13, v4.0.10 -> 4.0.10
function stableVersion(tag) {
  return tag.replace(/^v/, "").replace(/_/g, ".");
}

// v3_4_0_preview1 -> 3.4.0-preview1, v4.1.0-preview1 -> 4.1.0-preview1
function prereleaseVersion(tag) {
  if (tag.includes(".")) return tag.replace(/^v/, "");
  return stableVersion(tag)
    .replace(/\.(preview)/i, "-$1")
    .replace(/\.(rc)/i, "-$1");
}

function escape(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Returns [{ version, tag }] for every release autobump would add a recipe for.
export function missingVersions(tags, recipeVersions) {
  const recipes = new Set(recipeVersions);
  const missing = [];

  const stable = [];
  for (const tag of tags) {
    if (PRERELEASE.test(tag)) continue;
    const version = stableVersion(tag);
    if (/^\d+\.\d+\.\d+$/.test(version)) stable.push({ version, tag });
  }

  const latestBySeries = new Map();
  for (const entry of stable) {
    const minor = entry.version.split(".").slice(0, 2).join(".");
    if (!supportedSeries(minor)) continue;
    const current = latestBySeries.get(minor);
    if (!current || compareVersions(entry.version, current.version) > 0) {
      latestBySeries.set(minor, entry);
    }
  }
  for (const entry of latestBySeries.values()) {
    if (!recipes.has(entry.version)) missing.push(entry);
  }

  for (const tag of tags) {
    if (!PRERELEASE.test(tag)) continue;
    const version = prereleaseVersion(tag);
    const minor = version.match(/^\d+\.\d+/)?.[0];
    if (!minor || !supportedSeries(minor)) continue;
    const stableTag = new RegExp(
      `^v(${escape(minor.replace(".", "_"))}_\\d+|${escape(minor)}\\.\\d+)$`,
    );
    if (tags.some((t) => stableTag.test(t))) continue;
    if (!recipes.has(version)) missing.push({ version, tag });
  }

  return missing;
}

// Reads the version keys under `rubies:` in recipes/rubies.yml. The file is
// machine-written by bin/update-ruby-recipe, so a line scan is enough and
// keeps the worker free of a YAML dependency.
export function recipeVersions(yaml) {
  const versions = [];
  let inRubies = false;
  for (const line of yaml.split("\n")) {
    if (/^\S/.test(line)) {
      inRubies = /^rubies:\s*$/.test(line);
      continue;
    }
    if (!inRubies) continue;
    const m = line.match(/^ {2}(['"]?)([^\s'":#][^'":]*)\1:\s*$/);
    if (m) versions.push(m[2]);
  }
  return versions;
}
