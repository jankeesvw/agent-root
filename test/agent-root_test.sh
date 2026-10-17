#!/usr/bin/env bash
# Runs agent-root against stand-ins for pkexec and notify-send that write
# down how they were called, so no dialog or notification appears.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/agent-root"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stubs="$work/stubs"
log="$work/log"
mkdir -p "$stubs"

# Each stand-in writes one line per argument, so quoting is visible.
# PKEXEC_SLEEP makes pkexec wait like a dialog nobody answers.
cat >"$stubs/pkexec" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$LOG/pkexec"
[ -n "${PKEXEC_SLEEP:-}" ] && exec sleep "$PKEXEC_SLEEP"
exit "${PKEXEC_EXIT:-0}"
EOF
# The outcome replaces the first notification, so it goes to its own file.
# OLD_NOTIFY acts like libnotify before 0.7.10, which has no --print-id.
cat >"$stubs/notify-send" <<'EOF'
#!/usr/bin/env bash
case " $* " in
  *" --print-id "*) [ -n "${OLD_NOTIFY:-}" ] && exit 1 ;;
esac
case " $* " in
  *" --replace-id="*) printf '%s\n' "$@" >"$LOG/notify-send.report" ;;
  *) printf '%s\n' "$@" >"$LOG/notify-send" ;;
esac
[ -n "${NOTIFY_FAILS:-}" ] && exit 1
case " $* " in *" --print-id "*) echo 42 ;; esac
exit 0
EOF
chmod +x "$stubs"/*

# A PATH with the basics but no pkexec or notify-send, to add stubs to.
bare="$work/bare"
mkdir -p "$bare"
for tool in bash env sed realpath dirname ls sleep cat; do
  ln -s "$(type -P "$tool")" "$bare/$tool"
done

# A program you can change yourself, which agent-root should refuse.
mkdir -p "$work/mine"
printf '#!/bin/sh\nexit 0\n' >"$work/mine/tool"
chmod +x "$work/mine/tool"

ls_path="$(type -P ls)"
touch_path="$(type -P touch)"
sed_path="$(type -P sed)"

failures=0
passed=0

# Runs agent-root with stdin from /dev/null, the way an agent runs it.
run() {
  rm -rf "$log"
  mkdir -p "$log"
  output=$(LOG="$log" PATH="${TEST_PATH:-$stubs:$PATH}" "$script" "$@" 2>&1 </dev/null)
  status=$?
}

check() {
  local name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  status: $status"
    echo "  output: $output"
  fi
}

called_with() {
  [ "$(cat "$log/$1" 2>/dev/null)" = "$2" ]
}

mentions() {
  grep -qF -- "$2" "$log/$1" 2>/dev/null
}

lacks() {
  ! grep -qF -- "$2" "$log/$1" 2>/dev/null
}

no_process() {
  ! pgrep -f "$1" >/dev/null
}

unset AGENT_ROOT_REASON AGENT_ROOT_HINT AGENT_ROOT_ALLOW_USER_PATHS
unset PKEXEC_EXIT PKEXEC_SLEEP NOTIFY_FAILS OLD_NOTIFY TEST_PATH

# Usage

run
check "no arguments is a usage error" [ "$status" -eq 64 ]
check "no arguments prints the usage" grep -q "usage: agent-root" <<<"$output"

run "List /root"
check "a reason without a command is a usage error" [ "$status" -eq 64 ]
check "nothing runs without a command" [ ! -e "$log/pkexec" ]

run "List /root" ""
check "an empty command is a usage error" [ "$status" -eq 64 ]
check "nothing runs for an empty command" [ ! -e "$log/pkexec" ]

run "Run as alice" --user alice ls
check "a command starting with a dash is refused" [ "$status" -eq 64 ]
check "it does not reach pkexec as an option" [ ! -e "$log/pkexec" ]

run --help
check "--help exits cleanly" [ "$status" -eq 0 ]
check "--help prints the usage" grep -q "usage: agent-root" <<<"$output"

# Running a command

run "List /root" ls -la /root
check "the command runs through pkexec by its full path" called_with pkexec "--disable-internal-agent"$'\n'"$ls_path"$'\n-la\n/root'
check "it exits like pkexec" [ "$status" -eq 0 ]
check "the notification names the reason" mentions notify-send "Root needed: List /root"
check "the notification shows the command" mentions notify-send "$ls_path -la /root"
check "the notification says where to approve" mentions notify-send "Approve it in the system dialog"
check "afterwards the notification says it is done" mentions notify-send.report "Done: List /root"
check "that replaces the first notification" mentions notify-send.report "--replace-id=42"
check "and goes away on its own" mentions notify-send.report "--expire-time=5000"

run "Make a file" touch "" "/tmp/a file with spaces"
check "arguments keep their spaces and empty ones" called_with pkexec "--disable-internal-agent"$'\n'"$touch_path"$'\n\n/tmp/a file with spaces'
check "the notification quotes them" mentions notify-send "$touch_path '' '/tmp/a file with spaces'"

run "Edit a file" sed -i 's/<b>x/&y/' /etc/hosts
check "markup in the command is escaped in the notification" mentions notify-send "'s/&lt;b&gt;x/&amp;y/'"
check "and not passed on as markup" lacks notify-send "<b>"
check "the command itself is unchanged" called_with pkexec "--disable-internal-agent"$'\n'"$sed_path"$'\n-i\ns/<b>x/&y/\n/etc/hosts'

long="$(printf 'x%.0s' {1..80})"
run "List a long path" ls "/root/$long"
check "a command the dialog cuts short is pointed out" mentions notify-send "The dialog shows only part of this command"

AGENT_ROOT_HINT="Touch your security key" run "List /root" ls /root
check "the hint can be replaced" mentions notify-send "Touch your security key"

# Which program runs

run "Run something" no-such-command-here
check "an unknown command exits 127" [ "$status" -eq 127 ]
check "and never reaches pkexec" [ ! -e "$log/pkexec" ]

run "Run my tool" "$work/mine/tool"
check "a program you can change yourself is refused" [ "$status" -eq 64 ]
check "it says why" grep -q "you can change it yourself" <<<"$output"
check "and never reaches pkexec" [ ! -e "$log/pkexec" ]

TEST_PATH="$work/mine:$stubs:$PATH" run "Run the tool" tool
check "so is one found first in your PATH" [ "$status" -eq 64 ]

AGENT_ROOT_ALLOW_USER_PATHS=1 run "Run my tool" "$work/mine/tool"
check "AGENT_ROOT_ALLOW_USER_PATHS lets it run" called_with pkexec "--disable-internal-agent"$'\n'"$work/mine/tool"

# The reason from the environment, for yay and paru

AGENT_ROOT_REASON="List /root" run ls /root
check "the reason can come from the environment" mentions notify-send "Root needed: List /root"
check "then every argument is the command" called_with pkexec "--disable-internal-agent"$'\n'"$ls_path"$'\n/root'

AGENT_ROOT_REASON="An old reason" run "List /root" ls /root
check "a leftover AGENT_ROOT_REASON next to a reason is refused" [ "$status" -eq 64 ]
check "it says why" grep -q "AGENT_ROOT_REASON is set" <<<"$output"
check "and nothing runs" [ ! -e "$log/pkexec" ]

# Outcomes

PKEXEC_EXIT=126 run "List /root" ls /root
check "a dismissed dialog exits 126" [ "$status" -eq 126 ]
check "a dismissal is reported as declined" mentions notify-send.report "Declined: List /root"

PKEXEC_EXIT=1 run "List /root" ls /root
check "a failing command exits like it" [ "$status" -eq 1 ]
check "a failure is reported with its exit status" mentions notify-send.report "Failed (exit 1): List /root"

rm -rf "$log"
mkdir -p "$log"
LOG="$log" PKEXEC_SLEEP=37.5 PATH="$stubs:$PATH" "$script" "List /root" ls /root </dev/null >/dev/null 2>&1 &
pid=$!
for _ in $(seq 50); do [ -e "$log/pkexec" ] && break; sleep 0.1; done
sleep 0.2
kill -TERM "$pid"
wait "$pid"
status=$?
output=""
check "an interrupted run exits 143" [ "$status" -eq 143 ]
check "and is reported as interrupted, not done" mentions notify-send.report "Interrupted: List /root"
sleep 0.2
check "and takes pkexec and its dialog down with it" no_process "sleep 37.5"

# Without notifications

NOTIFY_FAILS=1 run "List /root" ls /root
check "the command still runs when notifications fail" called_with pkexec "--disable-internal-agent"$'\n'"$ls_path"$'\n/root'
check "nothing is reported when no notification was shown" [ ! -e "$log/notify-send.report" ]

OLD_NOTIFY=1 run "List /root" ls /root
check "an old notify-send still shows the notification" mentions notify-send "Root needed: List /root"
check "without an outcome to replace it with" [ ! -e "$log/notify-send.report" ]

mkdir -p "$work/no-notify"
ln -s "$stubs/pkexec" "$work/no-notify/pkexec"
TEST_PATH="$work/no-notify:$bare" run "List /root" "$ls_path" /root
check "the command runs without notify-send installed" [ "$status" -eq 0 ]
check "through pkexec" [ -e "$log/pkexec" ]

TEST_PATH="$bare" run "List /root" ls /root
check "without pkexec it exits 127" [ "$status" -eq 127 ]
check "and says what is missing" grep -q "pkexec not found" <<<"$output"

echo "$passed passed, $failures failed"
[ "$failures" -eq 0 ]
