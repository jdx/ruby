# Ruby release watcher

A Cloudflare Worker that checks for new Ruby releases every minute and
dispatches the [autobump workflow](../.github/workflows/autobump.yml) as soon
as one appears, so a new Ruby is built and published within minutes instead
of whenever GitHub gets around to the hourly cron (which in practice fires
every several hours).

Each minute it reads `ruby/ruby`'s GitHub releases and this repo's
`recipes/rubies.yml`, and picks the versions autobump would add with the same
rules autobump uses. When something is missing, and no autobump run is in
progress or started within the cooldown, it dispatches autobump with
`rubies_only: true`. Autobump writes the recipe and pushes it, which starts
`release-new.yml` and the build, as before.

The cooldown is 3 minutes for a release published in the last 2 hours (its
tarball can reach cache.ruby-lang.org a little after the GitHub release), 30
minutes up to a day, and after that the watcher leaves it to the hourly cron
and its failure email.

That is two GitHub API calls a minute when nothing is new, well under the
authenticated rate limit.

## Deploy

Create a fine-grained token for `jdx/ruby` only, with **Actions: read and
write** (to list and dispatch autobump runs) and **Contents: read**. Then:

```sh
cd watcher
npx wrangler deploy
npx wrangler secret put GITHUB_TOKEN
```

Logs: `npx wrangler tail`, or the Worker's Observability tab. Each run logs
one line: `none`, `dispatched`, `running`, `cooldown` or `stale`, with the
missing versions.

## Test

```sh
node --test watcher/test/*.test.mjs
```
