#!/usr/bin/env bash
# Token-free installed Codex guard for config/codex-worker-home.
#
# The hermetic suites pin the launch prefix and switches fm-spawn emits and drive
# the proof with a fake codex readback; only the installed codex can show that its
# own effective-configuration readback reports what the proof expects. This guard
# runs bin/fm-exclude-tools-lib.sh's proof against the real binary with synthetic
# Codex homes: no login, no server connection, and no model request, since
# `codex mcp list` and `codex features list` only read configuration.
#
# It asserts the divergence that keeps the proof from passing vacuously: the same
# clean home reports connectors on without the launch switches and off with them.
# Enabled by default wherever codex and perl are installed;
# FM_CODEX_WORKER_HOME_LIVE=1 makes an absent tool a failure, and =0 skips.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CODEX_WORKER_HOME_LIVE codex perl

# shellcheck source=bin/fm-exclude-tools-lib.sh
. "$ROOT/bin/fm-exclude-tools-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-worker-home-live)
CODEX_VERSION=$(codex --version 2>/dev/null | head -n 1)

# new_case <name> <config.toml line>...: a config dir holding a worker home with
# exactly these lines, plus an empty git project to probe from.
new_case() {
  local dir=$TMP_ROOT/$1
  shift
  mkdir -p "$dir/config/codex-worker-home" "$dir/project"
  git -C "$dir/project" init -q
  printf '%s\n' "$@" > "$dir/config/codex-worker-home/config.toml"
  printf '%s\n' "$dir"
}

expect_refused() {  # <case-dir> <reason substring> <label>
  local out
  if out=$(fm_codex_worker_home_check "$1/config" "$1/project" 2>&1); then
    fail "$CODEX_VERSION: $3 was accepted: $out"
  fi
  assert_contains "$out" "$2" "$CODEX_VERSION: $3 refusal must name the reason"
}

test_installed_codex_reports_the_launch_switches_turning_connectors_off() {
  local dir off on
  dir=$(new_case divergence 'model = "gpt-5"')
  on=$(cd "$dir/project" && CODEX_HOME="$dir/config/codex-worker-home" codex features list 2>/dev/null |
    awk '$1 == "apps" { print $NF }')
  # shellcheck disable=SC2086  # FM_CODEX_WORKER_FLAGS is a fixed word list.
  off=$(cd "$dir/project" && CODEX_HOME="$dir/config/codex-worker-home" codex features list $FM_CODEX_WORKER_FLAGS 2>/dev/null |
    awk '$1 == "apps" { print $NF }')
  [ "$on" = true ] || fail "$CODEX_VERSION: a clean home must report apps on by default (got '${on:-nothing}'), or this guard proves nothing"
  [ "$off" = false ] || fail "$CODEX_VERSION: the launch switches must turn apps off (got '${off:-nothing}')"
  pass "$CODEX_VERSION: the launch switches turn the default-on connectors off"
}

test_installed_codex_proves_a_clean_worker_home() {
  local dir out
  dir=$(new_case clean 'model = "gpt-5"' '' '[features]' 'apps = false' 'plugins = false')
  out=$(fm_codex_worker_home_check "$dir/config" "$dir/project") ||
    fail "$CODEX_VERSION: a clean worker home was refused: $out"
  [ "$out" = "$(cd "$dir/config/codex-worker-home" && pwd -P)" ] ||
    fail "$CODEX_VERSION: the proof must print the worker home's path, got '$out'"
  pass "$CODEX_VERSION: a clean worker home is proven"
}

test_installed_codex_refuses_a_home_shaped_like_a_desktop_config() {
  local dir
  dir=$(new_case desktop 'model = "gpt-5"' '' \
    '[plugins."google-drive@openai-curated"]' 'enabled = true' '' \
    '[plugins."slack@openai-curated"]' 'enabled = true' '' \
    '[mcp_servers.helper]' 'command = "true"')
  expect_refused "$dir" 'configures plugins.google-drive@openai-curated' 'a desktop-shaped home'
  pass "$CODEX_VERSION: a home with Drive and Slack plugins is refused"
}

test_installed_codex_readback_catches_a_trusted_project_server() {
  local dir proj
  dir=$(new_case project-layer 'model = "gpt-5"')
  proj=$(cd "$dir/project" && pwd -P)
  printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$proj" >> "$dir/config/codex-worker-home/config.toml"
  mkdir -p "$dir/project/.codex"
  printf '%s\n' '[mcp_servers.gmail]' 'command = "true"' > "$dir/project/.codex/config.toml"
  expect_refused "$dir" 'enabled MCP servers: gmail' 'a trusted project adding an MCP server'
  pass "$CODEX_VERSION: the readback refuses an MCP server a trusted project adds"
}

test_installed_codex_launch_switches_are_accepted_by_mcp_list() {
  local dir
  dir=$(new_case flags 'model = "gpt-5"')
  # shellcheck disable=SC2086  # FM_CODEX_WORKER_FLAGS is a fixed word list.
  (cd "$dir/project" && CODEX_HOME="$dir/config/codex-worker-home" codex mcp list --json $FM_CODEX_WORKER_FLAGS >/dev/null 2>&1) ||
    fail "$CODEX_VERSION: codex mcp list rejected the launch switches"
  pass "$CODEX_VERSION: codex mcp list accepts the launch switches"
}

test_installed_codex_reports_the_launch_switches_turning_connectors_off
test_installed_codex_proves_a_clean_worker_home
test_installed_codex_refuses_a_home_shaped_like_a_desktop_config
test_installed_codex_readback_catches_a_trusted_project_server
test_installed_codex_launch_switches_are_accepted_by_mcp_list

echo "# all fm-codex-worker-home-live tests passed"
