# agent-root

Let your coding agent ask for root, and say why.

Coding agents like Claude Code and Codex run their commands without a terminal you can type in. So the moment one needs root, to install a package or restart a service, it either trips over the password prompt or hands you a command to paste into a terminal yourself. `agent-root` gives it a third option: it asks you, in the same dialog your desktop uses for everything else that needs root, and tells you why.

![Claude Code in a terminal, asked why Sidekiq can't connect to Redis, running agent-root "Install Valkey (Redis) for Sidekiq" pacman -S --noconfirm valkey. The system dialog in the middle asks to authorize "/usr/bin/pacman -S --noconfirm valkey", and a notification in the corner says "Root needed: Install Valkey (Redis) for Sidekiq"](screenshots/dialog.png)

Here Claude Code was asked why Sidekiq can't connect to Redis, found that nothing was installed, and ran `agent-root "Install Valkey (Redis) for Sidekiq" pacman -S --noconfirm valkey`. The dialog shows the exact command, the notification shows the reason, and nothing happens until you approve it with your password, your fingerprint or a touch of your security key. Press Escape and the agent gets a plain "Request dismissed" and exit code 126.

It is one bash script around `pkexec` and `notify-send`, which a Linux desktop already has. No daemon, no allowlist, no config file, and nothing that ever sees or stores your password.

## Install

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/jankeesvw/agent-root/main/agent-root -o ~/.local/bin/agent-root
chmod +x ~/.local/bin/agent-root
```

The script is about seventy lines, so read it first if you like. Or clone the repository and link it, which makes `git pull` your update:

```bash
git clone https://github.com/jankeesvw/agent-root.git
ln -s "$PWD/agent-root/agent-root" ~/.local/bin/agent-root
```

It needs polkit and a polkit agent running in your desktop session, which is the thing that draws the dialog. GNOME and KDE have one built in, Omarchy has one in its shell, and on other Hyprland or Sway setups `hyprpolkitagent` or `polkit-gnome` does the job. `notify-send` is optional: without it there is no notification, and the dialog works the same.

## Tell your agent

An agent does what its instruction file says, so put this in your `CLAUDE.md`, `AGENTS.md` or whatever yours reads:

```markdown
## Root access

When a command needs root, don't use sudo and don't ask me to run it. Run it with `agent-root "<why>" <command>`: I get a system dialog with the command and a notification with your reason, and approve it there. Keep the reason under 50 characters and write it so it makes sense without reading the chat, and say in the chat that a dialog is coming.

pkexec starts in /root with a minimal environment, so pass files as absolute paths. There is no terminal to answer prompts, so use flags like `pacman --noconfirm`. Exit code 126 means I declined: don't retry, ask me what to do instead. For AUR helpers use `AGENT_ROOT_REASON="<why>" yay --sudo agent-root -S --noconfirm <package>`, and never run yay itself as root.
```

In Claude Code, add `Bash(agent-root:*)` to `permissions.allow` in `~/.claude/settings.json`, so it doesn't ask you first in the terminal and then again in the dialog. From then on a request for root looks like the screenshot above, wherever you are on your desktop.

## Approve or decline

Approve, and the command runs as root, its output going back to the agent like any other command's. The notification turns into a short "Done" and goes away on its own.

![Claude Code after the install was approved, saying "Installed. Next I'll enable and start the service. Another approval dialog is coming.", and a notification saying "Done: Install Valkey (Redis) for Sidekiq"](screenshots/approved.png)

Decline, and the agent knows it didn't happen. Here Claude wanted Valkey to start on every boot as well, which is not something everyone wants on a laptop. Dismissing that dialog gave it exit code 126, so it stopped and asked how to go on.

![Claude Code after the second dialog was dismissed: "I didn't start Valkey, because the second dialog was dismissed (exit 126)", followed by three ways to finish and "Which do you want?"](screenshots/declined.png)

The exit code is the command's own when it ran, 126 when the dialog was dismissed, and 127 when authentication failed or no polkit agent answered. A command that ran and failed shows "Failed (exit 1)" in the notification, with its own exit code.

Every command asks again. polkit doesn't remember an approval for running a program as root the way sudo remembers a password for five minutes, and for this that is the point: each command your agent runs as root is one you saw.

## Approve with a security key or a fingerprint

The dialog asks for whatever PAM asks for when polkit authenticates. Add `pam_u2f` to `/etc/pam.d/polkit-1` and a touch of your FIDO key is enough; add `pam_fprintd` and your fingerprint is. On Omarchy, `omarchy-setup-security-fido2` and `omarchy-setup-security-fingerprint` do this for you.

Not every dialog says so. Some keep showing a password field while the key is blinking, so the notification has a line for it that you can change:

```bash
export AGENT_ROOT_HINT="Touch your security key"
```

Put that in the profile your agent's shell loads, like `~/.bashrc`.

## AUR helpers

yay and paru call sudo themselves, with nothing but the command, so they take `agent-root` in sudo's place and the reason comes from the environment:

```bash
AGENT_ROOT_REASON="Install the Valkey server" yay --sudo agent-root -S --noconfirm valkey
AGENT_ROOT_REASON="Install the Valkey server" paru --sudo agent-root -S --noconfirm valkey
```

The helper builds as you and only asks when pacman has to install, which is what the dialog then shows.

## Why not sudo

`sudo -n`, the flag for "don't ask", fails whenever a password or a touch is needed, which is always. Plain `sudo` asks on a terminal the agent doesn't have. And `NOPASSWD` in sudoers gives the agent root for everything without you ever seeing what it does with it.

`agent-root` keeps you in the loop for every single command, with the command and the reason in front of you, without making you switch to a terminal to do it.

## Good to know

pkexec runs the command in `/root` with a minimal environment, so relative paths and your own environment variables don't come along. Pass files as absolute paths.

The agent has to run in your desktop session, because that is where the polkit agent listens. In an SSH session or a container there is nobody to draw the dialog: pkexec then asks for a password on the terminal if there is one, and otherwise exits 127.

The notification works with any notification daemon that follows the freedesktop spec. It is replaced by the result rather than closed, because some daemons leave a notification on screen when its sender asks to close it.

## Tests

```bash
test/agent-root_test.sh
```

This runs the script against stand-ins for `pkexec` and `notify-send`, so no dialog or notification appears. CI runs it and ShellCheck on every push.

## License

MIT
