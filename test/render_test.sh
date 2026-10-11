#!/usr/bin/env bash
#
# Renders every layout against the fixtures in test/fixtures and checks the output.
# Uses the static strategy so the result never depends on the live API.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAYOUTS=(full half_horizontal half_vertical quadrant)
EMPTY_STATE="No active community goal"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

build() {
  local fixture="$1" dir="$WORK/$1"
  mkdir -p "$dir/src"
  cp "$ROOT"/src/*.liquid "$dir/src/"
  printf -- '---\ncustom_fields: {}\nvariables: {}\n' > "$dir/.trmnlp.yml"
  {
    echo "---"
    echo "strategy: static"
    grep "^framework_version:" "$ROOT/src/settings.yml"
    echo "static_data: |"
    sed 's/^/  /' "$ROOT/test/fixtures/$fixture.json"
  } > "$dir/src/settings.yml"

  if command -v trmnlp > /dev/null; then
    trmnlp build --quiet --dir "$dir"
  else
    docker run --rm --volume "$dir:/plugin" trmnl/trmnlp build --quiet
  fi
}

fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}

expect() {
  local fixture="$1" layout="$2" text="$3"
  grep -qF -- "$text" "$WORK/$fixture/_build/$layout.html" || fail "$fixture/$layout should contain '$text'"
}

reject() {
  local fixture="$1" layout="$2" text="$3"
  ! grep -qF -- "$text" "$WORK/$fixture/_build/$layout.html" || fail "$fixture/$layout should not contain '$text'"
}

# Every fixture must render without broken maths or template errors.
check_clean() {
  local fixture="$1" layout="$2"
  reject "$fixture" "$layout" "NaN"
  reject "$fixture" "$layout" "Infinity"
  reject "$fixture" "$layout" "Liquid error"
}

check_goal() {
  local fixture="$1" percent="$2" fill="$3" layout
  build "$fixture"
  for layout in "${LAYOUTS[@]}"; do
    check_clean "$fixture" "$layout"
    expect "$fixture" "$layout" "Fixture Trade Initiative"
    expect "$fixture" "$layout" "$percent %"
    expect "$fixture" "$layout" "width: $fill%"
    reject "$fixture" "$layout" "$EMPTY_STATE"
  done
}

check_empty_state() {
  local fixture="$1" layout
  build "$fixture"
  for layout in "${LAYOUTS[@]}"; do
    check_clean "$fixture" "$layout"
    expect "$fixture" "$layout" "$EMPTY_STATE"
    reject "$fixture" "$layout" "Goal Progress"
  done
}

check_goal active 25.0 25.0
check_goal over_target 125.0 100
check_goal zero_target 0 0
check_empty_state no_goals
check_empty_state no_data

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All render checks passed"
