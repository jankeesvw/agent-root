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
cat >"$stubs/pkexec" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$LOG/pkexec"
exit "${PKEXEC_EXIT:-0}"
EOF
# notify-send is called twice, so the second call goes to its own file.
cat >"$stubs/notify-send" <<'EOF'
#!/usr/bin/env bash
if [ -e "$LOG/notify-send" ]; then
  printf '%s\n' "$@" >"$LOG/notify-send.report"
else
  printf '%s\n' "$@" >"$LOG/notify-send"
fi
[ -n "${NOTIFY_FAILS:-}" ] && exit 1
case " $* " in *" --print-id "*) echo 42 ;; esac
EOF
chmod +x "$stubs"/*

failures=0
passed=0

run() {
  rm -rf "$log"
  mkdir -p "$log"
  output=$(LOG="$log" PATH="$stubs:$PATH" "$script" "$@" 2>&1)
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

unset AGENT_ROOT_REASON AGENT_ROOT_HINT PKEXEC_EXIT NOTIFY_FAILS

run
check "no arguments is a usage error" [ "$status" -eq 64 ]
check "no arguments prints the usage" grep -q "usage: agent-root" <<<"$output"

run "Install htop"
check "a reason without a command is a usage error" [ "$status" -eq 64 ]
check "nothing runs without a command" [ ! -e "$log/pkexec" ]

run --help
check "--help exits cleanly" [ "$status" -eq 0 ]
check "--help prints the usage" grep -q "usage: agent-root" <<<"$output"

run "Install htop" pacman -S --noconfirm htop
check "the command runs through pkexec" called_with pkexec $'pacman\n-S\n--noconfirm\nhtop'
check "it exits like pkexec" [ "$status" -eq 0 ]
check "the notification names the reason" mentions notify-send "Root needed: Install htop"
check "the notification shows the command" mentions notify-send "pacman -S --noconfirm htop"
check "afterwards the notification says it is done" mentions notify-send.report "Done: Install htop"
check "that replaces the first notification" mentions notify-send.report "--replace-id=42"
check "and goes away on its own" mentions notify-send.report "--expire-time=5000"
check "the notification says where to approve" mentions notify-send "Approve it in the system dialog"

AGENT_ROOT_HINT="Touch your security key" run "Install htop" pacman -S htop
check "the hint can be replaced" mentions notify-send "Touch your security key"
unset AGENT_ROOT_HINT

run "Make a file" touch "/tmp/a file with spaces"
check "arguments keep their spaces" called_with pkexec $'touch\n/tmp/a file with spaces'

AGENT_ROOT_REASON="Install htop" run pacman -S htop
check "the reason can come from the environment" mentions notify-send "Root needed: Install htop"
check "then every argument is the command" called_with pkexec $'pacman\n-S\nhtop'
unset AGENT_ROOT_REASON

PKEXEC_EXIT=126 run "Install htop" pacman -S htop
check "a dismissed dialog exits 126" [ "$status" -eq 126 ]
check "a dismissal is reported as declined" mentions notify-send.report "Declined: Install htop"
unset PKEXEC_EXIT

PKEXEC_EXIT=1 run "Install htop" pacman -S htop
check "a failing command exits like it" [ "$status" -eq 1 ]
check "a failure is reported with its exit status" mentions notify-send.report "Failed (exit 1): Install htop"
unset PKEXEC_EXIT

NOTIFY_FAILS=1 run "Install htop" pacman -S htop
check "the command still runs without notifications" called_with pkexec $'pacman\n-S\nhtop'
check "nothing is reported when no notification was shown" [ ! -e "$log/notify-send.report" ]
unset NOTIFY_FAILS

echo "$passed passed, $failures failed"
[ "$failures" -eq 0 ]
