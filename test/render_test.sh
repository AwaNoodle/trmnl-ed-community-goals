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
  local name="$1" fixture="$2" show_all="$3" dir="$WORK/$1"
  mkdir -p "$dir/src"
  cp "$ROOT"/src/*.liquid "$dir/src/"
  printf -- '---\ncustom_fields:\n  show_all_goals: %s\nvariables: {}\n' "$show_all" > "$dir/.trmnlp.yml"
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
  local name="$1" layout="$2" text="$3"
  grep -qF -- "$text" "$WORK/$name/_build/$layout.html" || fail "$name/$layout should contain '$text'"
}

reject() {
  local name="$1" layout="$2" text="$3"
  ! grep -qF -- "$text" "$WORK/$name/_build/$layout.html" || fail "$name/$layout should not contain '$text'"
}

expect_count() {
  local name="$1" layout="$2" text="$3" count="$4" found
  found="$( { grep -oF -- "$text" "$WORK/$name/_build/$layout.html" || true; } | wc -l | tr -d ' ')"
  [ "$found" -eq "$count" ] || fail "$name/$layout should contain '$text' $count time(s), found $found"
}

# Every fixture must render without broken maths or template errors, and with the inline title bar icon.
check_clean() {
  local name="$1" layout="$2"
  reject "$name" "$layout" "NaN"
  reject "$name" "$layout" "Infinity"
  reject "$name" "$layout" "Liquid error"
  expect "$name" "$layout" 'src="data:image/svg+xml;base64,PHN2Zy'
}

check_goal() {
  local fixture="$1" percent="$2" fill="$3" layout name
  for show_all in false true; do
    name="$fixture-$show_all"
    build "$name" "$fixture" "$show_all"
    for layout in "${LAYOUTS[@]}"; do
      check_clean "$name" "$layout"
      expect "$name" "$layout" "Fixture Trade Initiative"
      expect "$name" "$layout" "$percent %"
      expect "$name" "$layout" "class=\"fill\" style=\"width: $fill%\""
      expect_count "$name" "$layout" "Goal Progress" 1
      reject "$name" "$layout" "$EMPTY_STATE"
    done
    expect "$name" full "Fixture bulletin text."
  done
}

check_empty_state() {
  local fixture="$1" layout name
  for show_all in false true; do
    name="$fixture-$show_all"
    build "$name" "$fixture" "$show_all"
    for layout in "${LAYOUTS[@]}"; do
      check_clean "$name" "$layout"
      expect "$name" "$layout" "$EMPTY_STATE"
      reject "$name" "$layout" "Goal Progress"
    done
  done
}

check_all_goals() {
  local fixture="$1" shown="$2" name="$1-true" layout
  build "$name" "$fixture" true
  for layout in "${LAYOUTS[@]}"; do
    check_clean "$name" "$layout"
    expect "$name" "$layout" "Fixture Goal 1"
    reject "$name" "$layout" "$EMPTY_STATE"
  done
  expect_count "$name" full "Goal Progress" "$shown"
  for layout in half_horizontal half_vertical quadrant; do
    expect_count "$name" "$layout" "Goal Progress" 1
    reject "$name" "$layout" "Fixture Goal 2"
  done
}

check_goal active 25.0 25.0
check_goal over_target 125.0 100
check_goal zero_target 0 0
# An unfinished goal never rounds up to 100 % or a full bar.
check_goal almost_complete 99.99 99.99
check_empty_state no_goals
check_empty_state no_data

build two_goals-false two_goals false
check_clean two_goals-false full
expect_count two_goals-false full "Goal Progress" 1
expect two_goals-false full "Fixture bulletin 1."
expect two_goals-false full "2 Active Goals"
reject two_goals-false full "Fixture Goal 2"

check_all_goals two_goals 2
expect two_goals-true full "Fixture Goal 2"
expect two_goals-true full 'class="fill" style="width: 25.0%"'
expect two_goals-true full 'class="fill" style="width: 75.0%"'
expect two_goals-true full "2026-10-12"
expect two_goals-true full "Fixture Objective 2"
expect two_goals-true full "Fixture bulletin 1."
expect two_goals-true full "Fixture bulletin 2."
reject two_goals-true full "Fixture System 1"

check_all_goals three_goals 3
expect three_goals-true full "Fixture Goal 3"
expect three_goals-true full "150.0 %"
expect three_goals-true full 'class="fill" style="width: 100%"'
reject three_goals-true full "Fixture Objective 1"

check_all_goals five_goals 4
expect five_goals-true full "Fixture Goal 4"
expect five_goals-true full 'class="fill" style="width: 0%"'
expect five_goals-true full "5 Active Goals"
reject five_goals-true full "Fixture Goal 5"

# A goal with a blank objective shows no empty Objective label or column.
build blank_objective-false blank_objective false
check_clean blank_objective-false full
expect blank_objective-false full "Fixture Goal 1"
reject blank_objective-false full '<span class="title">Objective</span>'

build blank_objective-true blank_objective true
check_clean blank_objective-true full
expect_count blank_objective-true full '<span class="label">Objective</span>' 1
expect blank_objective-true full "Fixture Objective 2"

if [ "$failures" -gt 0 ]; then
  echo "$failures check(s) failed"
  exit 1
fi
echo "All render checks passed"
