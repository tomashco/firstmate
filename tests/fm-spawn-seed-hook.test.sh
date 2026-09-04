#!/usr/bin/env bash
# Regression test for the project worktree preparation step in bin/fm-spawn.sh
# (config/seed-hooks/<project>, docs/configuration.md "Project worktree seeding
# hooks").
#
# The behavior under test is an ORDERING, so ordering is what this suite pins.
# A task worktree of some projects reaches an interactive prompt during shell
# startup; a pane held at such a prompt is not reading a command line, so every
# line typed into it is consumed as a value. That is how a typed launch brief
# overwrote credentials in a file shared by every copy of the project. The fix
# is that no shell may enter the copy until the project's own preparation step
# has answered whatever that startup would prompt for.
#
# Every case here drives fm-spawn through a fake tmux that appends each
# send-keys payload to one ordered log, and through hooks that append their own
# marker to the SAME log. The ordering assertion is then a plain question about
# that log: does the hook's marker precede every line typed into the pane?
#
# No real interactive prompt is exercised, and none may be: a live
# devenv/secretspec prompt writes into the operator's real credential file. The
# blocking-prompt case is simulated with a hook that reads stdin instead.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-seed-hook)

# A fake tmux that logs EVERY send-keys payload, in order, to FM_SEND_ORDER_LOG.
# The shared spawn fixture logs only `-l` literal payloads, which would hide the
# plain `cd` that moves the pane into the copy - the exact step whose position
# relative to the hook this suite exists to prove.
make_seed_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_PANE_PATH_FILE:-}" ] && [ -f "$FM_FAKE_PANE_PATH_FILE" ]; then
      cat "$FM_FAKE_PANE_PATH_FILE"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    # Log the payload arguments only: drop the subcommand, the -t target pair,
    # the -l literal flag and a trailing Enter, so the log is the ordered list
    # of what a shell in that pane would have been asked to read.
    if [ -n "${FM_SEND_ORDER_LOG:-}" ]; then
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          -t) shift 2 ;;
          -l) shift ;;
          Enter) shift ;;
          *) printf 'SEND %s\n' "$1" >> "$FM_SEND_ORDER_LOG"; shift ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# A fake treehouse whose `get --lease` prints FM_FAKE_LEASE_PATH on stdout and a
# banner on stderr, matching the real CLI's contract, and whose `return`
# records that it was asked to release a path.
install_fake_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}${2:-}" in
  getget|get--lease|get*)
    case "$*" in
      *--lease*)
        [ -z "${FM_FAKE_LEASE_FAIL:-}" ] || { printf 'pool exhausted\n' >&2; exit 1; }
        printf 'leased a worktree\n' >&2
        printf '%s\n' "${FM_FAKE_LEASE_PATH:-}"
        exit 0
        ;;
    esac
    exit 0
    ;;
  return*)
    if [ -n "${FM_FAKE_RETURN_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_RETURN_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# make_case <name> <id> -> builds a home, a project with a real worktree, the
# fake tools, and the ordered send log. The worktree is the path the fake lease
# hands out, so the prepared copy and the leased copy are the same directory the
# spawn must validate.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_seed_fakebin "$case_dir/fake")
  install_fake_treehouse "$fakebin"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config/seed-hooks"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the worktree preparation ordering for $id.

## Firstmate spec
Prepare the copy before any shell enters it.
EOF
  touch "$home/state/.last-watcher-beat"
  CASE_DIR=$case_dir
  HOME_DIR=$home
  PROJ_DIR=$proj
  WT_DIR=$wt
  FAKEBIN_DIR=$fakebin
  SEND_LOG="$case_dir/send-order.log"
  RETURN_LOG="$case_dir/treehouse-return.log"
  PANE_PATH_FILE="$case_dir/pane-path"
  : > "$SEND_LOG"
  : > "$RETURN_LOG"
  # The pane reports the worktree from the first read, so the entry check is
  # never what fails. That is deliberate: it leaves the ordering assertion as
  # the only thing that can catch a spawn which types before it prepares, so a
  # reversal is reported as a reversal rather than as an unrelated timeout.
  printf '%s\n' "$wt" > "$PANE_PATH_FILE"
}

# write_hook <path> <exit-code> writes a hook that appends its marker to the
# ordered send log and exits with the given code.
write_hook() {
  local path=$1 code=$2
  cat > "$path" <<EOF
#!/usr/bin/env bash
set -u
printf 'HOOK %s\n' "\$*" >> "$SEND_LOG"
exit $code
EOF
  chmod +x "$path"
}

run_spawn() {
  local id=$1
  shift
  local spawn_home="$CASE_DIR/user-home"
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH_FILE="$PANE_PATH_FILE" \
    FM_FAKE_LEASE_PATH="${FM_FAKE_LEASE_PATH_OVERRIDE:-$WT_DIR}" \
    FM_SEND_ORDER_LOG="$SEND_LOG" FM_FAKE_RETURN_LOG="$RETURN_LOG" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

# line_index <log> <pattern> -> 1-based line number of the first match, or 0.
line_index() {
  local n
  n=$(grep -n -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1)
  printf '%s\n' "${n:-0}"
}

# --- the ordering itself ----------------------------------------------------

# THE case this change exists for. A successful hook must complete before the
# pane is sent anywhere, and the launch command must come after both. This
# assertion fails if the launch, or even the cd that enters the copy, can
# precede the preparation step.
test_hook_completes_before_anything_is_typed() {
  local id out status hook_at first_send_at launch_at
  id=seed-order-a1
  make_case seed-order "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 0

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the preparation step succeeds"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  hook_at=$(line_index "$SEND_LOG" '^HOOK ')
  first_send_at=$(line_index "$SEND_LOG" '^SEND ')
  # The launch line is the one carrying the brief path - the very text that was
  # consumed as secret values when it met a prompt.
  launch_at=$(line_index "$SEND_LOG" '^SEND .*brief')
  [ "$hook_at" -gt 0 ] || fail "the preparation step never ran"
  [ "$first_send_at" -gt 0 ] || fail "nothing was ever typed into the pane"
  [ "$hook_at" -lt "$first_send_at" ] \
    || fail "the pane was typed into at line $first_send_at, before the preparation step at line $hook_at - a shell could reach an interactive prompt first"
  [ "$launch_at" -eq 0 ] || [ "$hook_at" -lt "$launch_at" ] \
    || fail "the launch command reached the pane before the preparation step"
  pass "a preparation step completes before any line is typed into the pane"
}

# The pane must never be sent `treehouse get`, whose subshell enters the copy
# before firstmate knows its path - which is what put the pane at the prompt.
test_hooked_project_never_types_treehouse_get() {
  local id status
  id=seed-noget-a2
  make_case seed-noget "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 0

  run_spawn "$id" >/dev/null
  status=$?
  expect_code 0 "$status" "spawn should succeed"
  assert_no_grep 'treehouse get' "$SEND_LOG" \
    "a hooked project typed treehouse get into the pane instead of leasing the copy"
  assert_grep "cd " "$SEND_LOG" "the pane was never sent into the prepared copy"
  pass "a hooked project leases its copy instead of typing treehouse get into the pane"
}

# --- refusals ---------------------------------------------------------------

test_failed_hook_refuses_with_nothing_typed() {
  local id out status
  id=seed-fail-a3
  make_case seed-fail "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 1

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a failing preparation step"
  assert_contains "$out" "exited 1" "the refusal did not report the step's exit code"
  assert_no_grep 'SEND ' "$SEND_LOG" \
    "a failing preparation step still let text reach the pane"
  [ ! -f "$HOME_DIR/state/$id.meta" ] \
    || fail "a refused spawn left a task record behind"
  pass "a failing preparation step refuses the spawn with nothing typed into the pane"
}

# A step that reports partial success is telling firstmate the copy is not
# ready. One such seeder uses exit 3 for exactly this and says in as many
# words not to treat the worktree as ready, so it must refuse like any other
# non-zero exit - and the code must be reported so the operator sees WHICH.
test_partial_success_refuses_and_names_its_code() {
  local id out status
  id=seed-partial-a4
  make_case seed-partial "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 3

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a partially prepared copy"
  assert_contains "$out" "exited 3" "the refusal did not name the partial-success exit code"
  assert_no_grep 'SEND ' "$SEND_LOG" \
    "a partially prepared copy still received typed text"
  pass "a preparation step reporting partial success refuses the spawn and names its code"
}

# A hook that blocks on stdin stands in for a step that reaches an interactive
# prompt. It must see end-of-input and fail rather than being answered, and no
# firstmate text may reach it. A real secrets prompt is deliberately not used:
# answering one writes to the operator's own credential file.
test_hook_that_reads_stdin_sees_eof_and_refuses() {
  local id out status hook
  id=seed-stdin-a5
  make_case seed-stdin "$id"
  hook="$HOME_DIR/config/seed-hooks/project"
  cat > "$hook" <<EOF
#!/usr/bin/env bash
set -u
printf 'HOOK reading\n' >> "$SEND_LOG"
if IFS= read -r answer; then
  printf 'HOOK consumed:%s\n' "\$answer" >> "$SEND_LOG"
  exit 0
fi
printf 'no input available for the secrets prompt\n' >&2
exit 1
EOF
  chmod +x "$hook"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "a step that could not read its prompt still let the spawn proceed"
  assert_grep 'HOOK reading' "$SEND_LOG" "the step never ran"
  assert_no_grep 'HOOK consumed:' "$SEND_LOG" \
    "the preparation step consumed a line of firstmate's text as an answer"
  assert_no_grep 'SEND ' "$SEND_LOG" "text reached the pane despite the refusal"
  pass "a preparation step that reaches a prompt sees end-of-input and refuses instead of being answered"
}

# A declared hook that cannot be executed is a configuration error, and it must
# be caught before an endpoint or a lease exists.
test_non_executable_hook_refuses_early() {
  local id out status
  id=seed-nonexec-a6
  make_case seed-nonexec "$id"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_DIR/config/seed-hooks/project"
  chmod -x "$HOME_DIR/config/seed-hooks/project"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn proceeded past a non-executable preparation step"
  assert_contains "$out" "not an executable file" "the refusal did not name the cause"
  assert_no_grep 'SEND ' "$SEND_LOG" "a misconfigured step still let text reach the pane"
  pass "a declared but non-executable preparation step refuses before anything is created"
}

# A refusal BEFORE the preparation step ran has allocated nothing outside the
# worktree, so the slot goes straight back to the pool.
test_refusal_before_the_step_releases_the_lease() {
  local id out
  id=seed-release-a7
  make_case seed-release "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 0
  # The leased path is not a worktree at all, so the isolation check refuses
  # between the lease and the step.
  mkdir -p "$CASE_DIR/not-a-worktree"
  out=$(FM_FAKE_LEASE_PATH_OVERRIDE="$CASE_DIR/not-a-worktree" run_spawn "$id") || true
  assert_no_grep 'HOOK ' "$SEND_LOG" "the step ran despite the refusal"
  assert_grep "return --force $CASE_DIR/not-a-worktree" "$RETURN_LOG" \
    "a refusal before the step did not release the worktree it leased"
  pass "a refusal before the preparation step releases the copy it leased"
}

# treehouse commits the lease in its persistent state before it prints the
# path, so a refusal on the printed path itself must still give the slot back.
# Recording the lease only after that check would leak it with no `treehouse
# return` attempted and no remedy printed.
test_lease_of_a_missing_path_is_released() {
  local id out
  id=seed-missingpath-b3
  make_case seed-missingpath "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 0

  out=$(FM_FAKE_LEASE_PATH_OVERRIDE="$CASE_DIR/vanished-slot" run_spawn "$id") || true
  assert_contains "$out" "which is not a directory" "the refusal did not name the missing leased path"
  assert_no_grep 'HOOK ' "$SEND_LOG" "the step ran against a path that does not exist"
  assert_grep "return --force $CASE_DIR/vanished-slot" "$RETURN_LOG" \
    "a lease whose path does not exist was not returned to the pool"
  pass "a lease whose printed path does not exist is still returned to the pool"
}

# A refusal AFTER the step ran must NOT return the slot: the step may have
# allocated databases, remote branches or ports that only that project's own
# release step can free, and a returned slot is handed to the next task while
# those are still allocated. The operator is told instead.
test_refusal_after_the_step_keeps_the_lease() {
  local id out
  id=seed-keeplease-b2
  make_case seed-keeplease "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 1

  out=$(run_spawn "$id") || true
  assert_grep 'HOOK ' "$SEND_LOG" "the step never ran"
  assert_no_grep 'return' "$RETURN_LOG" \
    "a refusal after the step returned a slot whose external resources are still allocated"
  assert_contains "$out" "left leased" "the refusal did not say the slot was kept"
  assert_contains "$out" "release step" "the refusal did not name the remedy"
  pass "a refusal after the preparation step keeps the lease and names the release step"
}

test_successful_spawn_keeps_its_lease() {
  local id
  id=seed-keep-a8
  make_case seed-keep "$id"
  write_hook "$HOME_DIR/config/seed-hooks/project" 0

  run_spawn "$id" >/dev/null
  assert_no_grep 'return' "$RETURN_LOG" \
    "a successful spawn released the copy its worker is about to work in"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the task record does not name the prepared copy"
  pass "a successful spawn keeps its lease for the worker and its cleanup"
}

# --- projects with no hook stay on the untouched path -----------------------

# The guarantee that firstmate's own repo and every un-hooked project spawn as
# before. The distinguishing evidence is the pane traffic: no hook means the
# pane is sent `treehouse get` exactly as it always was, and no lease is taken.
test_project_with_no_hook_is_unaffected() {
  local id out status
  id=seed-nohook-a9
  make_case seed-nohook "$id"
  rm -rf "$HOME_DIR/config/seed-hooks"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "an un-hooked project should spawn exactly as before"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep 'treehouse get' "$SEND_LOG" \
    "an un-hooked project no longer types treehouse get into the pane"
  assert_no_grep 'HOOK ' "$SEND_LOG" "something ran for a project that declares no step"
  assert_no_grep 'return' "$RETURN_LOG" "an un-hooked project took and released a lease"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the task record does not name the worktree the pane settled in"
  pass "a project that declares no preparation step spawns exactly as it did before"
}

# The declaration is per project, so one project's hook must not reach another.
test_hook_is_scoped_to_its_own_project() {
  local id out status
  id=seed-scope-b1
  make_case seed-scope "$id"
  rm -f "$HOME_DIR/config/seed-hooks/project"
  write_hook "$HOME_DIR/config/seed-hooks/some-other-project" 1

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "another project's preparation step was applied to this one"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_no_grep 'HOOK ' "$SEND_LOG" "another project's step ran"
  pass "a preparation step applies only to the project it is declared for"
}

test_hook_completes_before_anything_is_typed
test_hooked_project_never_types_treehouse_get
test_failed_hook_refuses_with_nothing_typed
test_partial_success_refuses_and_names_its_code
test_hook_that_reads_stdin_sees_eof_and_refuses
test_non_executable_hook_refuses_early
test_refusal_before_the_step_releases_the_lease
test_lease_of_a_missing_path_is_released
test_refusal_after_the_step_keeps_the_lease
test_successful_spawn_keeps_its_lease
test_project_with_no_hook_is_unaffected
test_hook_is_scoped_to_its_own_project

echo "# all fm-spawn-seed-hook tests passed"
