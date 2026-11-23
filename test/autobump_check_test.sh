#!/usr/bin/env bash
# Exercises the `check` job of .github/workflows/autobump.yml against fixtures.
#
# The job's script is extracted from the workflow, so this tests the code that
# runs in CI. `git ls-remote` and `curl` are stubbed with fixture files; `yq`
# is the real one (preinstalled on GitHub runners). The stub also emits a peeled
# (^{}) entry for every tag, as ls-remote does for annotated tags.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

ruby -ryaml -e '
  steps = YAML.load_file(ARGV.fetch(0)).fetch("jobs").fetch("check").fetch("steps")
  puts steps.find { |s| s["id"] == "compare" }.fetch("run")
' "$root/.github/workflows/autobump.yml" > "$work/check.sh"

mkdir "$work/bin"
cat > "$work/bin/git" <<'STUB'
#!/usr/bin/env bash
[ "$1" = ls-remote ] || { echo "unexpected git $*" >&2; exit 1; }
while read -r tag; do
  printf '0000000000000000000000000000000000000000\trefs/tags/%s\n' "$tag"
  printf '1111111111111111111111111111111111111111\trefs/tags/%s^{}\n' "$tag"
done < "$FIXTURE_TAGS"
STUB
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat "$FIXTURE_RECIPES"
STUB
chmod +x "$work/bin/git" "$work/bin/curl"

failures=0

# run_check NAME EXPECTED "TAGS (space separated)" "RECIPE VERSIONS (space separated)"
run_check() {
  local name=$1 expected=$2 tags=$3 recipes=$4
  # shellcheck disable=SC2086
  printf '%s\n' $tags > "$work/tags"
  {
    echo "schema: 1"
    echo "rubies:"
    for v in $recipes; do echo "  $v:"; echo "    series: x"; done
  } > "$work/recipes.yml"
  : > "$work/output"
  FIXTURE_TAGS="$work/tags" FIXTURE_RECIPES="$work/recipes.yml" GITHUB_OUTPUT="$work/output" \
    PATH="$work/bin:$PATH" RECIPES_URL=unused \
    bash -eo pipefail "$work/check.sh" > "$work/log" 2>&1 || { cat "$work/log"; echo "FAIL $name: script errored"; failures=$((failures + 1)); return; }
  local got
  got=$(sed -n 's/^needs_bump=//p' "$work/output")
  if [ "$got" = "$expected" ]; then
    echo "ok   $name"
  else
    cat "$work/log"
    echo "FAIL $name: expected needs_bump=$expected, got '$got'"
    failures=$((failures + 1))
  fi
}

old="v1_9_3_551 v2_7_8 v3_1_6 v3_2_0_rc1 v3_3_0_preview1"
both="v3_2_11 v3_3_13 v3_4_12 v4.0.9"

run_check "recipes are current" false \
  "$old $both" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "new stable, underscore tag" true \
  "$old $both v3_4_13" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "new stable, dotted tag" true \
  "$old $both v4.0.10" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "only the newest stable per series is required" false \
  "$old $both" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "older patch missing, newest present" false \
  "v3_4_11 v3_4_12" "3.4.12"
run_check "series older than 3.2 are ignored" false \
  "$old v3_1_7 $both" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "new prerelease, underscore tag" true \
  "$both v4_2_0_preview1" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "new prerelease, dotted tag" true \
  "$both v4.2.0-preview1" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "new rc, underscore tag" true \
  "$both v4_2_0_rc1" "3.2.11 3.3.13 3.4.12 4.0.9"
run_check "recorded prerelease" false \
  "$both v4_2_0_preview1 v4.3.0-preview2" "3.2.11 3.3.13 3.4.12 4.0.9 4.2.0-preview1 4.3.0-preview2"
run_check "prerelease in a series that has a stable release" false \
  "$both v3_4_0_rc1 v3_4_0_preview1 v4.0.0-preview3" "3.2.11 3.3.13 3.4.12 4.0.9"

if [ "$failures" -ne 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
