#!/bin/bash
# mcp-e2e.sh: end-to-end check of the MCP slice-2 paths against a real app build.
#
# Everything below runs the shipped artifacts for real: the built `portmaster-mcp`
# speaks MCP over stdio, and the built Portmaster.app is launched, binds its socket and
# answers through it. Nothing is stubbed and no state is simulated, which is why this
# exists next to the unit tests rather than instead of them.
#
#   Phase 1 — app closed. The CLI must find no host, fall back to its own sweep, refuse
#             a mutation and leave a `denied` audit line.
#   Phase 2 — app launched. The endpoint file and socket must exist with owner-only
#             modes, `tools/list` over the socket must return 13 tools, and a
#             `set_preference` must reach a person and produce a decision on the record.
#
# ONE MANUAL STEP. Phase 2's last check needs a click. `confirmEach` means "ask a person",
# and the person is a SwiftUI window no shell can press; there is no accessibility hook,
# no test seam and no notification-center shortcut in this release. The script therefore
# sends the call, prints what to look for, and waits for you to click Allow (or Deny —
# both are recorded, and both are a passing run). Everything before the click is
# asserted automatically. Pass --no-manual to skip phase 2's confirmation entirely; the
# script then reports that check as SKIPPED rather than pretending it passed.
#
# WHAT IT TOUCHES. It writes to the real per-user `~/.portmaster`: an audit line per
# mutation attempt (that is the point), a `mcpMode` setting, and the app's own socket.
# The settings file is copied before it is changed and put back by a trap, whatever the
# outcome. The audit log is appended to and never truncated.
#
# Usage: mcp-e2e.sh [--no-manual] /absolute/path/Portmaster.app /absolute/path/portmaster-mcp
set -euo pipefail

# --- arguments ---------------------------------------------------------------

allow_manual=1
if [[ "${1:-}" == "--no-manual" ]]; then
    allow_manual=0
    shift
fi
if [[ $# -ne 2 ]]; then
    echo 'Usage: mcp-e2e.sh [--no-manual] /absolute/Portmaster.app /absolute/portmaster-mcp' >&2
    exit 2
fi
app_path="$1"
cli_path="$2"
[[ "$app_path" = /* && "$cli_path" = /* ]] || { echo 'Use absolute paths.' >&2; exit 2; }
[[ -d "$app_path/Contents/MacOS" && -f "$app_path/Contents/Info.plist" ]] \
    || { echo 'First argument must be a built .app bundle.' >&2; exit 2; }
[[ -x "$cli_path" ]] || { echo 'Second argument must be an executable portmaster-mcp.' >&2; exit 2; }

# --- the real per-user state -------------------------------------------------

state_dir="$HOME/.portmaster"
endpoint_file="$state_dir/mcp-endpoint.json"
socket_path="$state_dir/mcp.sock"
settings_file="$state_dir/mcp-settings.json"
audit_log="$state_dir/mcp-audit.log"

# How long to wait for the app to bind. Generous because a cold launch pays a
# one-time cost for its first sweep; a bound below it would report a slow launch as a
# broken one.
launch_timeout=30
# The confirmation window resolves itself after ConfirmationBroker.defaultTimeout (60s);
# this is a little longer, so a line arriving late is still this run's doing.
confirm_timeout=75

work_dir=$(/usr/bin/mktemp -d /tmp/portmaster-mcp-e2e.XXXXXX)
settings_backup="$work_dir/mcp-settings.json.backup"
settings_existed=0
[[ -f "$settings_file" ]] && { cp "$settings_file" "$settings_backup"; settings_existed=1; }

cleanup() {
    # Restore the user's mutation mode before anything else, so an interrupted run
    # cannot leave their assistant authorized to act on their machine.
    if [[ $settings_existed -eq 1 ]]; then
        cp "$settings_backup" "$settings_file" 2>/dev/null \
            || echo "WARN: could not restore $settings_file from the backup" >&2
    else
        rm -f "$settings_file"
    fi
    if [[ -n "${launched_pid:-}" ]] && kill -0 "$launched_pid" 2>/dev/null; then
        # Asked to quit first, then signalled. `osascript` reaches the same
        # `applicationShouldTerminate` path the menu's Quit does, which is what runs
        # the async `stop()` that unlinks the socket and the endpoint file; a signal
        # alone skips it and leaves both on disk for the next run to misread.
        /usr/bin/osascript -e 'tell application id "dev.portmaster.app" to quit' \
            >/dev/null 2>&1 || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$launched_pid" 2>/dev/null || break
            /bin/sleep 1
        done
        # Escalate rather than leave a socket bound behind: this run launched the app
        # and is responsible for putting the machine back the way it found it.
        if kill -0 "$launched_pid" 2>/dev/null; then
            echo 'WARN: Portmaster did not quit; signalling it directly.' >&2
            kill -TERM "$launched_pid" 2>/dev/null || true
            /bin/sleep 2
        fi
        if kill -0 "$launched_pid" 2>/dev/null; then
            kill -KILL "$launched_pid" 2>/dev/null || true
        fi
    fi
    /bin/rm -rf "$work_dir"
}
trap cleanup EXIT

# --- reporting ---------------------------------------------------------------

passed=0
failed=0
skipped=0

pass() { printf 'PASS  %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; failed=$((failed + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; skipped=$((skipped + 1)); }
note() { printf '      %s\n' "$1"; }

check() { # check <description> <actual> <expected>
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

section() { printf '\n== %s\n' "$1"; }

# --- audit helpers -----------------------------------------------------------

# Lines in the audit log right now. Counted, not tailed: every check below is about
# what *this run* appended, and a `tail -1` on a shared log would read somebody else's
# line the moment two of these ran at once.
audit_lines() {
    [[ -f "$audit_log" ]] || { echo 0; return; }
    grep -c '' "$audit_log" 2>/dev/null || echo 0
}

# Every audit line this run appended, as raw JSON lines.
new_audit_lines() { # new_audit_lines <from>
    local from="$1"
    [[ -f "$audit_log" ]] || return 0
    tail -n "+$((from + 1))" "$audit_log" 2>/dev/null || true
}

# The `outcome` of the first appended line naming <tool>, or the empty string.
outcome_for() { # outcome_for <from> <tool>
    new_audit_lines "$1" | python3 -c '
import json, sys
tool = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get("tool") == tool:
        print(entry.get("outcome", ""))
        break
' "$2"
}

# --- MCP session plumbing ----------------------------------------------------

# One MCP session over stdio, requests from stdin, the whole transcript on stdout.
# stdout carries JSON-RPC and nothing else, so the transcript is safe to parse; the
# route's diagnostics go to stderr, which is why that is captured separately.
mcp_session() { # mcp_session <out-file> <err-file> <request-json>...
    local out="$1" err="$2"
    shift 2
    printf '%s\n' "$@" | "$cli_path" >"$out" 2>"$err" || true
}

initialize_request() {
    printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-e2e","version":"0"}}}'
}
initialized_notification() {
    printf '{"jsonrpc":"2.0","method":"notifications/initialized"}'
}
tools_call() { # tools_call <id> <tool> <arguments-json>
    printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":%s}}' \
        "$1" "$2" "$3"
}

# --- phase 0: preconditions --------------------------------------------------

section 'Phase 0 — preconditions'

if /usr/bin/pgrep -x Portmaster >/dev/null 2>&1; then
    echo 'error: Portmaster is already running. Quit it (⌘Q) and run this again —' >&2
    echo '       phase 1 is defined by the app being closed.' >&2
    exit 2
fi
pass 'Portmaster is not running'
[[ -f "$settings_file" ]] || printf '{ "mode": "off" }\n' >"$settings_file"
chmod 600 "$settings_file"

# The embedded CLI is what a real user runs, so it is checked here rather than in a
# unit test: a bundle whose post-build script did not run ships a "Copy install
# command" button with nothing to name.
if [[ -x "$app_path/Contents/Resources/portmaster-mcp" ]]; then
    pass 'the app bundle ships portmaster-mcp in Contents/Resources'
else
    fail 'the app bundle ships portmaster-mcp in Contents/Resources'
fi

# --- phase 1: app closed -----------------------------------------------------

section 'Phase 1 — app closed: refusal and audit line'

before=$(audit_lines)
out="$work_dir/phase1.out"
err="$work_dir/phase1.err"
mcp_session "$out" "$err" \
    "$(initialize_request)" \
    "$(initialized_notification)" \
    "$(tools_call 2 quit_app '{"id":"mcp-e2e-no-such-app"}')"

if grep -q 'no Portmaster answering on the socket' "$err"; then
    pass 'the CLI said it found no host and fell back to its own sweep'
else
    fail 'the CLI did not report the no-host fallback'
    note "stderr: $(tr '\n' ' ' <"$err")"
fi

# Parsed, not grepped: the SDK writes `"isError": true` with a space after the colon,
# and a substring match on JSON is the kind of check that passes on the wrong build.
is_error=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 2:
        print("true" if message.get("result", {}).get("isError") is True else "false")
        break
' "$out")
check 'quit_app was refused with isError set (not a transport failure)' "$is_error" 'true'

text=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 2:
        parts = message.get("result", {}).get("content", [])
        print(" ".join(part.get("text", "") for part in parts))
        break
' "$out")
if [[ -n "$text" ]]; then
    pass 'the refusal names itself rather than arriving as a transport failure'
    note "text: $text"
else
    fail 'the refusal carried no text'
fi

after=$(audit_lines)
check 'exactly one audit line was appended' "$((after - before))" '1'
check 'the audit line says denied' "$(outcome_for "$before" quit_app)" 'denied'

# --- phase 2: app launched ---------------------------------------------------

section 'Phase 2 — app launched: socket, catalog, confirmation'

# `confirmEach` is written directly rather than through a tool call because reaching
# it through one needs the confirmation it enables. Copied back by the trap.
printf '{ "mode": "confirmEach" }\n' >"$settings_file"
chmod 600 "$settings_file"

# `open <bundle>`, not `open -a`: -a takes a registered application *name*, and this is
# a path to a bundle that may never have been registered under one.
/usr/bin/open "$app_path"
launched_pid=''
# Polls for a pid that is *alive*, not merely for one written in a file. A crashed or
# killed launch leaves both the endpoint file and the socket behind, and reading the
# stale file's pid would satisfy this loop instantly — pointing every later check, and
# the cleanup's signal, at a process that ended before this run began.
for _ in $(seq 1 "$launch_timeout"); do
    if [[ -S "$socket_path" ]]; then
        candidate=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1]))["pid"])
except Exception:
    print("")
' "$endpoint_file")
        if [[ -n "$candidate" ]] && kill -0 "$candidate" 2>/dev/null; then
            launched_pid="$candidate"
            break
        fi
    fi
    /bin/sleep 1
done

if [[ -n "$launched_pid" ]]; then
    pass "the app bound its socket and wrote the endpoint file (pid $launched_pid)"
else
    fail "the app did not bind its socket within ${launch_timeout}s"
    note 'nothing after this can run; the remaining phase 2 checks are skipped'
fi

if [[ -f "$endpoint_file" ]]; then
    check 'the endpoint file is owner-only (0600)' "$(/usr/bin/stat -f '%Lp' "$endpoint_file")" '600'
else
    fail 'the endpoint file is missing'
fi
if [[ -S "$socket_path" ]]; then
    pass "the socket exists at $socket_path"
else
    fail "the socket is missing at $socket_path"
fi
check 'the state directory is owner-only (0700)' "$(/usr/bin/stat -f '%Lp' "$state_dir")" '700'

# --- tools/list over the socket ----------------------------------------------

out="$work_dir/phase2-list.out"
err="$work_dir/phase2-list.err"
mcp_session "$out" "$err" \
    "$(initialize_request)" \
    "$(initialized_notification)" \
    '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}'

tool_count=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 3:
        print(len(message.get("result", {}).get("tools", [])))
        break
' "$out")
check 'tools/list over the socket returns 13 tools' "$tool_count" '13'

# --- a relayed mutation that needs nobody -------------------------------------
#
# The point of this block is that it asserts something the `pending` check below cannot:
# **that the app itself recorded the attempt.** A call the CLI is still waiting on proves
# only that the CLI has not been told anything — which is also what "nothing arrived" looks
# like. Only the app's own audit line can tell those apart, so this makes a relayed
# mutation, has the app refuse it, and looks for the refusal *in the app's log*.

section 'Phase 2b — a relayed mutation the app itself refuses'

refusal_before=$(audit_lines)
# Guarded on the app being up, like the read block below: with it down the CLI falls back
# to its own sweep and refuses the call itself, which is a different fact and would pass
# every check below while proving nothing about the relay.
if [[ -z "$launched_pid" ]]; then
    fail 'the app was not running, so this phase could not have exercised the relay'
fi
out="$work_dir/phase2b.out"
err="$work_dir/phase2b.err"
mcp_session "$out" "$err" \
    "$(initialize_request)" \
    "$(initialized_notification)" \
    "$(tools_call 6 quit_app '{"id":"mcp-e2e-no-such-app"}')"

refusal_after=$(audit_lines)
# Two different facts, two variables: what came back down the socket, and what the app
# wrote to its own log. Reading one into the other is how a check ends up passing on the
# wrong evidence — which it did, the first time.
refusal_is_error=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 6:
        # `isError` lives on the result object; the text is the refusal sentence, which
        # is prose and must never be parsed as JSON.
        print("error" if message.get("result", {}).get("isError") is True else "ok")
        break
' "$out")
refusal_outcome=$(outcome_for "$refusal_before" quit_app)

check 'the relayed call came back with isError set' "$refusal_is_error" 'error'
check 'the app wrote the refusal to its own audit log' "$refusal_outcome" 'denied'

# The app and the CLI are different processes with different pids, and only the app
# hosts the gate — so a line carrying the CLI's pid would mean the refusal came from the
# on-demand path and this check proved nothing.
app_pid=$(python3 -c '
import json, sys
try:
    print(json.load(open(sys.argv[1]))["pid"])
except Exception:
    print("")
' "$endpoint_file")
# Only the lines *this phase* appended: the log is shared and cumulative, so "the first
# quit_app in the file" is whichever run got there first, not this one.
relayed_pid=$(python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except ValueError:
        continue
    if entry.get("tool") == "quit_app":
        print(entry.get("pid", ""))
        break
' < <(new_audit_lines "$refusal_before"))
check 'the refusal was written by the app, not by the CLI' "$relayed_pid" "$app_pid"

# --- a relayed read, answered by the app --------------------------------------

# `tools/list` above proves the catalog arrived, which is static. This proves a *call*
# round-tripped to the app and came back with the app's own answer — the thing the relay
# exists for, and the thing `--no-manual` otherwise never exercised.
settings_out="$work_dir/phase2-settings.out"
settings_err="$work_dir/phase2-settings.err"
mcp_session "$settings_out" "$settings_err" \
    "$(initialize_request)" \
    "$(initialized_notification)" \
    "$(tools_call 5 get_settings '{}')"

settings_error=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 5:
        result = message.get("result", {})
        print("error" if result.get("isError") else "ok")
        break
' "$settings_out")
check 'a relayed read came back without an error' "$settings_error" 'ok'
# Guarded on the app actually being up: with it down the CLI falls back to its own
# sweep and answers the same request, so the check would pass without having
# exercised the relay at all.
if [[ -z "$launched_pid" ]]; then
    fail 'the app was not running, so these checks could not have exercised the relay'
fi
relayed_mode=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 5:
        text = "".join(
            part.get("text", "") for part in message.get("result", {}).get("content", [])
        )
        print(json.loads(text).get("mutationMode", ""))
        break
' "$settings_out")
if [[ -n "$relayed_mode" ]]; then
    pass "the app answered get_settings with its own mutation mode ($relayed_mode)"
else
    fail 'get_settings returned no mutation mode, so the relay answered nothing'
fi

# --- a confirmation, and what it records --------------------------------------

if [[ $allow_manual -eq 1 && -n "$launched_pid" ]]; then
    # The value written back is whatever the machine already reports, so an approved
    # confirmation changes nothing. A test that turns the user's temperature unit to
    # Fahrenheit on the way past is a test nobody runs twice.
    #
    # `temperatureUnit`, and not `mcpMode`: the confirmation window validates a
    # preference change against the app's own preferences store, which does not own
    # `mcpMode` and refuses it by name — so a `mcpMode` change can never reach a
    # person. See task-10-report.md; this is a defect, not a property of the script.
    unit=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 5:
        text = "".join(
            part.get("text", "") for part in message.get("result", {}).get("content", [])
        )
        print(json.loads(text).get("temperatureUnit", ""))
        break
' "$settings_out")
    if [[ -n "$unit" ]]; then
        pass "get_settings reports temperatureUnit=$unit, so the write below changes nothing"
    else
        fail 'get_settings reported no temperature unit; falling back to celsius'
        unit=celsius
    fi

    note "A window titled \"Confirm AI Request\" will open in Portmaster, asking to set"
    note "temperatureUnit to ${unit}. Click Allow (or Deny) when it does. You have 60"
    note 'seconds; the prompt resolves itself if nobody answers, and that is'
    note 'recorded as a denial. Bring Portmaster forward if the window is behind'
    note 'whatever you are using — it is a menu bar app and does not steal focus.'
    note 'Press Enter here once you have decided.'

    before=$(audit_lines)
    out="$work_dir/phase2-confirm.out"
    err="$work_dir/phase2-confirm.err"
    # stdin is held open for the whole wait, which is what a real MCP client does for
    # the life of its session. `printf | cli` would close the pipe the moment the last
    # request was written, and the server's EOF drain is ~10s — shorter than the 60s a
    # confirmation may wait — so the process would exit, the socket would close and the
    # answer would never arrive. This script is not allowed to hold the product to a
    # client behaviour it does not have; see task-10-report.md for the honest note.
    #
    # The arguments are built into a variable FIRST, then passed unquoted-in-quotes as
    # one word. Writing the JSON inline as
    # `"$(tools_call 4 set_preference "{\"key\":\"…\"}")"` does not do what it looks
    # like: the escaped quotes end the *outer* argument, so printf receives the
    # arguments as separate words and emits one malformed tools/call per piece —
    # `arguments":"key":…` and `arguments":"value":…`. The SDK rejected both as parse
    # errors and the real set_preference was never sent, so no confirmation was ever
    # requested, so no audit line ever appeared. The two failures below ("no audit line
    # appeared for the confirmed set_preference" and "the confirmed call answered on the
    # socket") were this, not the confirmation machinery: nothing had been asked of it.
    # Verified by dumping the session's own transcript — two `-32700` parse errors and
    # an initialize, with no valid tools/call anywhere in it.
    preference_args=$(printf '{"key":"temperatureUnit","value":"%s"}' "$unit")
    ( printf '%s\n' \
        "$(initialize_request)" \
        "$(initialized_notification)" \
        "$(tools_call 4 set_preference "$preference_args")"
      /bin/sleep "$confirm_timeout" ) \
        | "$cli_path" >"$out" 2>"$err" &
    session_pid=$!

    # The strongest claim this script can make without a click: the relayed call is
    # *pending*. An app that answered immediately would have refused it outright, so
    # silence here is the observable difference between "the app received the request
    # and is holding it for a person" and "nothing arrived".
    /bin/sleep 4
    if kill -0 "$session_pid" 2>/dev/null && ! grep -q '"id": *4' "$out" 2>/dev/null; then
        pass 'the relayed set_preference is pending — the app is holding it for a decision'
    else
        fail 'the set_preference was answered without waiting for a person'
    fi

    read -r -p '  [press Enter after you decide] ' _ || true

    outcome=''
    for _ in $(seq 1 "$confirm_timeout"); do
        outcome=$(outcome_for "$before" set_preference)
        [[ -n "$outcome" ]] && break
        kill -0 "$session_pid" 2>/dev/null || break
        /bin/sleep 1
    done
    wait "$session_pid" 2>/dev/null || true

    case "$outcome" in
        allowed)
            pass 'the approved mutation was recorded as allowed'
            ;;
        denied)
            pass 'the refused (or unanswered) confirmation was recorded as denied'
            note 'a denial is a correct outcome — the point is that a person decided'
            ;;
        '')
            fail 'no audit line appeared for the confirmed set_preference'
            note "stderr: $(tr '\n' ' ' <"$err")"
            ;;
        *)
            fail "the confirmation recorded an unexpected outcome: $outcome"
            ;;
    esac

    # An approved write answers with the value that was applied; a refusal answers with
    # the reason. Either way the transcript must be JSON-RPC, not silence.
    answered=$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("id") == 4:
        print("yes" if ("result" in message or "error" in message) else "no")
        break
' "$out")
    check 'the confirmed call answered on the socket' "$answered" 'yes'
else
    skip 'the confirmation decision (needs a click; re-run without --no-manual)'
fi

# --- summary -----------------------------------------------------------------

section 'Summary'
printf '%s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
if [[ $failed -gt 0 ]]; then
    echo 'mcp-e2e: FAILED'
    exit 1
fi
echo 'mcp-e2e: OK'