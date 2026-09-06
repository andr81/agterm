# Remote Claude session

One chord opens a tab that runs Claude Code inside a tmux session on a remote host, reconnects on its own, and reports the agent's status onto its own sidebar row.

## What it does

A laptop that goes to sleep, gets closed, or comes along in a bag takes every local agent with it. Moving the agent to a server that stays up fixes that, and the price is usually a handful of manual steps every time: ssh in, find or create the tmux session, `cd` to the project, start the agent, and do it all again after the connection drops.

This recipe folds those steps into two chords and one script on each side.

- **Open.** Press the key, and a picker lists the sessions already running on the host, then the projects it holds. Pick a session to reattach to it, or pick a project and type a name for a new one. A tab opens, named `⇅ name` so it reads as remote in the sidebar, in a workspace named after the project. Inside, ssh connects, tmux creates or attaches the session, and on the first creation Claude Code starts in the project's directory.
- **Reconnect.** When the connection drops, from sleep or a change of network, the tab reconnects a few seconds later by itself; the tmux session and the agent in it never noticed. After an agterm restart the tab comes back already reattaching, because its restore line is pinned to the same command.
- **Status.** The agent's lifecycle hooks on the host reach this tab's sidebar row through a port ssh forwards back to the local control socket, so the row pulses active, goes blocked on a permission prompt and flashes completed, the way a local session does.
- **End.** A second chord kills the remote tmux session, after a picker asks, and closes the tab. Detaching without killing is tmux's own `prefix d`, or just closing the tab: the session stays on the host, and the next open lists it.

Conversations survive more than the connection. The Claude Code session id is pinned to the tmux session's name on the host, so a host reboot brings the same conversation back with `--resume` on the next attach rather than starting a fresh one.

## Requirements

- agterm 0.22.0 or later, which fixed a custom command spawning with a `PATH` that could not resolve a bare `agtermctl`. The picker, `session new --command`, `session restore` and `session status --pane-id` the recipe rides on are all older than that.
- `jq`, `ssh` and `python3` on the Mac. Python runs the status relay; without it the tab still works and the row stays idle.
- On the host: `tmux`, `python3`, `uuidgen` (util-linux), `git`, and the Claude Code binary on the login shell's `PATH`. The recipe does not install it; it does carry your sign-in over, see Setup.
- Key-based ssh to the host that works without a prompt, from a process with no terminal: a key held by the macOS agent, or one without a passphrase. `rsync` on both sides for the optional `sync`.

## Setup

### On your Mac

Copy the three scripts somewhere together and make the local two executable; `install` below copies the host one across:

```sh
mkdir -p ~/bin
cp agt-remote.sh agt-remote-relay.py agt-remote-host.sh ~/bin/
chmod +x ~/bin/agt-remote.sh ~/bin/agt-remote-relay.py
```

Create `~/.config/agt-remote/config`. It is sourced by the script, so it is plain shell:

```sh
AGT_REMOTE_HOST=devbox                 # an ssh alias, or user@host
AGT_REMOTE_PROJECTS=projects           # the projects root on the host, relative to its $HOME or absolute
AGT_REMOTE_LOCAL_PROJECTS=$HOME/projects  # where the same projects live here, for the tab's local shell
AGT_REMOTE_COMMAND=claude              # what starts in a new session; may not contain a single quote
AGT_REMOTE_BADGE='⇅ '                  # the sidebar prefix; set it empty to keep bare names
```

A config file rather than variables on the keymap line, because two of the script's callers never see the keymap's environment: the tab's own process, and the line agterm replays after a restart.

Give the host an entry in `~/.ssh/config`. The `Control*` lines are what make the picker instant and let every tab share one connection; the `ServerAlive*` pair turns a dead connection into a reconnect within a minute instead of a frozen tab; `ForwardAgent` is what lets `git` on the host use this Mac's keys, so the host never holds one of its own:

```
Host devbox
  HostName 203.0.113.10
  User ubuntu
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  ForwardAgent yes
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m
  ServerAliveInterval 15
  ServerAliveCountMax 4
```

Add the chords to `~/.config/agterm/keymap.conf` and apply with File ▸ Reload Keymap:

```
command "Remote session" ctrl+shift+n>r ~/bin/agt-remote.sh open
command "Remote end"     ctrl+shift+n>x ~/bin/agt-remote.sh end "{AGT_SESSION_ID}"
```

Any chord with a modifier works; a leader pair is shown because the two commands read as one family. If `agtermctl` is not on your `PATH`, set `AGTERMCTL` to its full path in the config file.

### On the host

Everything on the host is done from the Mac, in four commands. Each is safe to run again.

**1. Install.**

```sh
~/bin/agt-remote.sh install
```

Copies `agt-remote-host.sh` to `~/.local/bin/` on the host, compiles the Mac's terminfo entry there (tmux refuses to start under a `TERM` the host cannot name, and `xterm-ghostty` is one it does not know), and runs the host script's `setup`, which: creates the projects root; appends to `~/.tmux.conf` the lines that let the agent's clipboard and notification escapes through and pin `SSH_AUTH_SOCK` to a fixed path; writes `~/.ssh/rc` to repoint that path at the forwarded agent on every login, so `git` keeps working inside tmux after a reattach; makes `~/.profile` source `~/.agt-remote/env`; copies this Mac's `known_hosts` entries for github.com and gitlab.com to the host, so the host trusts exactly the forge keys the Mac has already verified and nothing is scanned blind (no entry here means none there, and the first clone then fails with a host-key error: run `ssh -T git@github.com` on the Mac once and reinstall); and merges the four status hooks into `~/.claude/settings.json`. The merge keeps every hook already there, refuses to touch a file that is not valid JSON, keeps the file's mode, writes through a symlink rather than replacing it, and takes a timestamped backup only when it actually changes something. Those four events match what agterm's own **Install Agent Status Hooks…** wires up locally; `agt-remote-host.sh hooks` prints the block if you would rather merge it by hand.

**2. Sign in.** Claude Code on the host needs your subscription. On the Mac, `claude setup-token` opens the browser and prints a long-lived token; hand it over:

```sh
~/bin/agt-remote.sh auth
```

It asks for the token without echoing it and stores it on the host in `~/.agt-remote/env` as `CLAUDE_CODE_OAUTH_TOKEN`, mode 600. The agent is started through a `sh -c` wrapper that sources that file first, so the token reaches it whatever the login shell and whichever startup files it reads, and never appears on a command line; `~/.profile` sources the file as well, for a shell you open on the host by hand. Run it again to replace the token. Signing in on the host interactively instead, with `claude` and `/login`, works the same way and needs no token.

**3. Clone.** Every direct subdirectory of the projects root is one picker row:

```sh
~/bin/agt-remote.sh clone git@github.com:you/api.git
~/bin/agt-remote.sh clone git@gitlab.com:group/backend.git api-backend
```

The clone runs on the host with your Mac's ssh agent forwarded, so any key the agent holds works there; `ssh-add -l` shows what it holds, and `ssh-add --apple-use-keychain ~/.ssh/<key>` loads one. The second argument names the directory when the repository's own name is not the project's.

**4. Sync, optionally.**

```sh
~/bin/agt-remote.sh sync
```

Copies `~/.claude/CLAUDE.md`, `skills/`, `agents/` and `commands/`, whichever exist, to the host's `~/.claude/`, so the agent there follows the same instructions. Nothing else from `~/.claude` travels: `settings.json` carries this Mac's hooks and paths, and plugins are installed per machine.

## Usage

Press ⌃⇧N then R. The picker shows the host's running sessions first, each marked with the badge and noting whether something is attached, then the projects. Return on a session reattaches; Return on a project opens a second prompt, prefilled with the project's name, for the session's name. Esc anywhere opens nothing.

The tab opens in a workspace named after the project, with the badge in front of the session's name. Claude Code is already starting in the project's directory on the host.

Close the laptop, open it later: the tab prints that it lost the connection and is reconnecting, then the tmux session is back where you left it. Ctrl-C during the countdown stops the retrying and leaves a local shell in the tab.

Press ⌃⇧N then X in a remote tab to end it. The picker opens on "Leave running"; choose the kill row to stop the tmux session and close the tab. A plain ⌘W closes the tab and leaves the session running on the host.

From any shell, `~/bin/agt-remote.sh list` prints the host's sessions and projects, `~/bin/agt-remote.sh attach NAME PROJECT` reattaches by hand, and `clone` adds a project without leaving the Mac.

## How it works

The local script has three callers with three environments, and the design mostly follows from keeping them straight. The chord runs it detached, with `$AGT_SOCKET` and `$AGT_WINDOW_ID` and no terminal, so everything it has to say goes through `agtermctl notify`. The tab's process runs it with a terminal and the session's own `$AGTERM_*` variables. The restore line runs it typed into a fresh login shell after a restart. The config file is the one thing all three share.

`open` makes one ssh round trip, `agt-remote-host.sh list`, which prints running sessions and projects as TSV, and turns that into the picker's items with the session rows first. A picked session already carries its project, from tmux's own record of the directory it started in. A picked project opens a second `pick` with `--allow-custom` and no items, which is the palette's plain text prompt; the name is limited to letters, digits, `-` and `_`, since it becomes a tmux session name, a file name and an argv word on the remote command line.

The tab is `session new --command`, with the script itself as the command, so the process in the tab is the reconnect loop rather than a bare ssh. The loop runs `ssh -t` with the host script's `attach` as the remote command. Exit 255 is ssh's own "connection failed or dropped"; the loop waits `AGT_REMOTE_RETRY` seconds (5) and goes again. Any other exit is the remote command finishing, a detach or a killed session, and the loop hands the tab to a login shell so the scrollback stays readable and the tab does not vanish. `session restore` pins the same line, because the alternative, agterm's captured foreground, would replay the bare `ssh` and lose the loop.

On the host, `tmux new-session -d` followed by `attach-session -d` is the whole create-or-reattach story: `has-session` decides, and `-d` on attach detaches any other client so a tab forgotten on another machine cannot shrink this one. The agent starts through `send-keys` into the new session's shell rather than as the session's command, so when it exits the shell is still there and the tmux session survives. The typed line is a `sh -c` that sources the token file and execs the agent, which keeps the token off every command line and makes the launch the same under bash, zsh or fish. Its session id is a UUID minted on first creation and written to `~/.agt-remote/NAME.claude`; a later creation of a tmux session by the same name finds the file and, if the transcript exists under `~/.claude/projects/`, starts with `--resume` instead.

The status bridge has a relay on the Mac side, and that relay is the whole security story. `attach` starts `agt-remote-relay.py` on a unix socket under `~/.agt-remote/relay/`, mode 600, holding this tab's session id and pane token as fixed arguments, and forwards it with `ssh -R 127.0.0.1:PORT:<relay socket>`: a TCP port on the host, loopback only, that reaches the relay and nothing else. The relay reads one line, accepts it only if it is a `session.status` request whose status is one of the four states, rebuilds the request from scratch with its own target and pane, and only then speaks to agterm's control socket; every other line, including any target or pane the host tried to name, is answered `refused`. So what the host can do to the Mac is set this one tab's status, whatever else is on the host. The relay exits when the attach loop that started it is gone, so a hard-killed agterm leaves no listener behind.

The port is random and fresh for every connection, with `ExitOnForwardFailure` so a port that cannot bind fails the connection, which the loop retries with another port, rather than running the attach with no bridge. A host whose sshd refuses remote forwarding altogether would fail every attempt the same way, so on such a failure the loop first tries a plain connection: if that works, the forward is what the host refuses, and the session opens without its bridge and says so. A fixed port would break the recipe's own last-client-wins path: a tab taking a session over from another one would ask for the port that other tab still holds, ssh would carry on without the forward, and the row would stay dead for the whole attachment. On each attach the host script writes the port it was given to `~/.agt-remote/NAME.target`; the target itself never leaves the Mac. A hook fires inside the tmux session, asks tmux which session it is in (`display-message '#S'` through the inherited `$TMUX`), reads the port from that file, and sends one JSON line with a two-second timeout. Rewriting the file on every attach is what lets a tab opened tomorrow, or after an agterm restart with a new pane token, be the one that lights up: the new attach starts a new relay with the new token and a new port.

The `end` chord reads the tmux name from a marker the open wrote under `~/.agt-remote/`, keyed by session id, falling back to stripping the badge off the tab's name, so a tab restored from an earlier install still ends cleanly. The picker's first row is the harmless one, so a Return pressed by reflex leaves the session running.

## Limits

**`end` kills the remote tmux session and everything in it, then closes the local tab.** The agent, any server or watcher running in that session, and its scrollback on the host are gone; the tab's local scrollback goes with the tab. There is no undo on the host side. The picker is the one confirmation.

**Closing the tab any other way leaves the session running on the host.** ⌘W, a closed window, quitting agterm: none of them reach tmux. That is the point of the recipe, but it also means sessions accumulate on the host until you end them; `list` shows what is there.

**A remote tab is not restored by the "Restore running commands" denylist logic.** The pinned restore line bypasses the denylist by design, so the tab always reattaches after a restart, and the setting has to be on for it to happen at all. With it off, a restarted tab is a plain shell and `attach NAME PROJECT` by hand brings it back.

**The reconnect loop is not a session recovery.** It retries ssh; it cannot bring back a tmux session the host lost to a reboot. The next attach recreates one by the same name and resumes the conversation, if the transcript survived on the host, but whatever else ran in the old session is not started again.

**The status bridge lets the host set this tab's status, and only that.** Anything on the host that can reach the loopback port, another user on a shared host included, can make the row pulse, go blocked or flash completed for that tab. It cannot name another tab, run a command, read the tree or reach any other control command: the relay on the Mac rebuilds every request and refuses everything but a status. A wrong status is the worst case, and `AGT_REMOTE_STATUS=0` in the config removes even that: no relay, no port, and the hooks, if installed, post nowhere.

**Names are sanitized, not free.** A session name with a space becomes hyphens; one with a dot, colon or anything outside letters, digits, `-` and `_` is refused with a banner, because tmux reads `.` and `:` as target syntax. Project directories may carry dots.

**Two agents cannot share a name.** The conversation id is pinned to the tmux session's name, so `new-session` twice for the same name, with the first one gone but its transcript present, resumes that transcript rather than starting clean. Pick a fresh name for fresh work, or delete `~/.agt-remote/NAME.claude` on the host.

**The picker reads the host live.** With the host down or unreachable, the open chord raises a banner and opens nothing; there is no cached list. With `ControlMaster` configured the round trip is milliseconds, without it every open pays a full ssh handshake.

**Chords inside a scratch terminal or overlay can resolve to the wrong session.** `end` takes the session the chord fired in; from a scratch pane that may be a different tab than the one on screen. The picker names the session it is about to kill, so read the row.

**`AGT_REMOTE_COMMAND` and `AGT_REMOTE_PROJECTS` may not contain a single quote**, because both are spliced into a single-quoted word on the remote command line; the script refuses at startup rather than mangling them.

**`install` edits files on the host.** `~/.tmux.conf`, `~/.ssh/rc`, `~/.profile`, `~/.ssh/known_hosts` and `~/.claude/settings.json` each gain a marked block or entry, once; a `~/.ssh/rc` that already exists also stops sshd's default X11 handling, which a headless host does not miss. A `settings.json` that is not valid JSON is reported and left alone, and the hooks are then missing until you fix it and rerun.

**A failed reconnect pin is reported, not fixed.** If `session restore` cannot save the tab's reconnect line, the tab still opens and works, and a banner carries the exact `attach` command to run by hand after the next agterm restart. `sync` runs `rsync --delete` on the four items it copies, so a skill that exists only on the host is removed by the next sync.

**A host that forbids remote forwarding gets no statuses.** The tab still opens, after one extra probe connection and a line saying the forward was refused, and the row stays idle for that attachment. Ask the host's admin about `AllowTcpForwarding` and `PermitListen` if you want the bridge there.

**The token in `~/.agt-remote/env` is your subscription.** It is a file on the host, readable by your user there; treat host access as account access, and rotate it with `auth` if the host is ever shared or lost.
