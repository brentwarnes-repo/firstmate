#!/usr/bin/env bash
# Behavior tests for bin/fm-packet.sh: the local mechanism that records and
# checks bounded packet-scoped merge authority (AGENTS.md section 7). Covers
# the full lifecycle - open -> grant -> in/out-of-scope check -> close ->
# expired check - and the ordering guards (check before open, check before
# grant) that keep an unauthorized PR from ever reading as in-scope.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PACKET="$ROOT/bin/fm-packet.sh"
TMP_ROOT=$(fm_test_tmproot fm-packet)
NOW=2026-09-13T00:00:00Z

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

run_packet() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_PACKET_NOW="$NOW" "$PACKET" "$@"
}

test_check_before_open_refuses() {
  local home
  home=$(make_home before-open)
  if run_packet "$home" check ghost-packet --repo owner/repo \
    > "$TMP_ROOT/bo.out" 2> "$TMP_ROOT/bo.err"; then
    fail "check authorized a packet that was never opened"
  fi
  assert_grep "does not exist" "$TMP_ROOT/bo.err" "refusal did not name the missing packet"
  pass "check refuses an unknown packet"
}

test_full_lifecycle() {
  local home
  home=$(make_home lifecycle)
  run_packet "$home" open demo --repo owner/repo-a --repo owner/repo-b \
    --objective "ship the local controls" >/dev/null \
    || fail "open failed"
  assert_present "$home/data/packets/demo.record" "open did not write a record"

  if run_packet "$home" check demo --repo owner/repo-a \
    > "$TMP_ROOT/pre-grant.out" 2> "$TMP_ROOT/pre-grant.err"; then
    fail "check authorized an in-scope repo before the packet was granted"
  fi
  assert_grep "has not been granted" "$TMP_ROOT/pre-grant.err" \
    "pre-grant refusal did not name the missing grant"

  run_packet "$home" grant demo >/dev/null || fail "grant failed"

  run_packet "$home" check demo --repo owner/repo-a >/dev/null \
    || fail "an in-scope repo under a granted, open packet was refused"
  run_packet "$home" check demo --repo owner/repo-b >/dev/null \
    || fail "the second in-scope repo was refused"

  if run_packet "$home" check demo --repo owner/repo-c \
    > "$TMP_ROOT/oos.out" 2> "$TMP_ROOT/oos.err"; then
    fail "check authorized a repo outside the packet's declared scope"
  fi
  assert_grep "outside packet demo's scope" "$TMP_ROOT/oos.err" \
    "out-of-scope refusal did not name the boundary"

  run_packet "$home" close demo >/dev/null || fail "close failed"

  if run_packet "$home" check demo --repo owner/repo-a \
    > "$TMP_ROOT/expired.out" 2> "$TMP_ROOT/expired.err"; then
    fail "check authorized a repo after the packet closed"
  fi
  assert_grep "merge authority has expired" "$TMP_ROOT/expired.err" \
    "post-close refusal did not name the expiry"

  pass "the full packet lifecycle (open -> grant -> scoped check -> close -> expired) behaves as authorized"
}

test_open_refuses_duplicate() {
  local home
  home=$(make_home duplicate)
  run_packet "$home" open dup --repo owner/repo --objective "first" >/dev/null \
    || fail "first open failed"
  if run_packet "$home" open dup --repo owner/repo --objective "second" \
    > "$TMP_ROOT/dup.out" 2> "$TMP_ROOT/dup.err"; then
    fail "a second open silently replaced an existing packet"
  fi
  assert_grep "already exists" "$TMP_ROOT/dup.err" "duplicate-open refusal did not name the boundary"
  pass "open refuses to silently replace an existing packet"
}

test_close_refuses_twice() {
  local home
  home=$(make_home double-close)
  run_packet "$home" open once --repo owner/repo --objective "one shot" >/dev/null \
    || fail "open failed"
  run_packet "$home" close once >/dev/null || fail "first close failed"
  if run_packet "$home" close once \
    > "$TMP_ROOT/close2.out" 2> "$TMP_ROOT/close2.err"; then
    fail "a second close on an already-closed packet was accepted"
  fi
  assert_grep "already closed" "$TMP_ROOT/close2.err" "double-close refusal did not name the boundary"
  pass "close refuses a packet that is already closed"
}

test_grant_refuses_on_closed_packet() {
  local home
  home=$(make_home grant-after-close)
  run_packet "$home" open late --repo owner/repo --objective "too late" >/dev/null \
    || fail "open failed"
  run_packet "$home" close late >/dev/null || fail "close failed"
  if run_packet "$home" grant late \
    > "$TMP_ROOT/grant-late.out" 2> "$TMP_ROOT/grant-late.err"; then
    fail "grant succeeded on an already-closed packet"
  fi
  assert_grep "not open" "$TMP_ROOT/grant-late.err" "late-grant refusal did not name the boundary"
  pass "grant refuses a closed packet"
}

test_check_before_open_refuses
test_full_lifecycle
test_open_refuses_duplicate
test_close_refuses_twice
test_grant_refuses_on_closed_packet
