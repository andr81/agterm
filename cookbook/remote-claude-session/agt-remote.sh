#!/bin/sh
# agt-remote.sh - run a coding agent in a tmux session on a remote host, one
# agterm tab per remote session, reconnecting on its own. See README.md.
#
#   open                  chord: pick a remote session to reattach, or a project
#                         and a name for a new one, and open a tab for it
#   attach NAME PROJECT   the tab's own process: ssh to the host and (re)attach
#   end [SESSION-ID]      chord: kill the tab's remote tmux session, close the tab
#   list                  print the host's sessions and projects
#   install               copy agt-remote-host.sh to the host and prepare it
#   auth                  store the agent's OAuth token on the host, read from a
#                         hidden prompt or stdin
#   clone URL [NAME]      clone a repository under the host's projects root
#   sync                  copy ~/.claude instructions, skills, agents, commands over
#
# DESTRUCTIVE: `end` kills the remote tmux session and everything running in
# it, then closes the local tab. Read the README's Limits.
set -u

AGTERMCTL=${AGTERMCTL:-agtermctl}
CONFIG=${AGT_REMOTE_CONFIG:-$HOME/.config/agt-remote/config}
STATE_DIR=${AGT_REMOTE_STATE:-$HOME/.agt-remote}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# a config file, not keymap-line variables: the tab's process and the restore
# line agterm replays after a restart never see the keymap's environment.
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

HOST=${AGT_REMOTE_HOST:-}
PROJECTS=${AGT_REMOTE_PROJECTS:-projects}
LOCAL_PROJECTS=${AGT_REMOTE_LOCAL_PROJECTS:-$HOME/projects}
COMMAND=${AGT_REMOTE_COMMAND:-claude}
# no colon: an empty AGT_REMOTE_BADGE means "no badge", not "the default"
BADGE=${AGT_REMOTE_BADGE-⇅ }
REMOTE_BIN=${AGT_REMOTE_BIN:-.local/bin/agt-remote-host.sh}
RETRY=${AGT_REMOTE_RETRY:-5}
# 0 opens no port on the host and posts no statuses
STATUS=${AGT_REMOTE_STATUS:-1}

# a chord exports AGT_SOCKET; a session's process exports AGTERM_SOCKET.
socket=${AGT_SOCKET:-${AGTERM_SOCKET:-}}
window=${AGT_WINDOW_ID:-${AGTERM_WINDOW_ID:-}}

# the socket path holds a space on a default install; one wrapper keeps every
# call quoted, and --socket is a subcommand option, so it goes last.
agt() {
	if [ -n "$socket" ]; then
		"$AGTERMCTL" "$@" --socket "$socket"
	else
		"$AGTERMCTL" "$@"
	fi
}

# a chord's stdout and stderr go to /dev/null, so the banner is the only channel
notify() {
	agt notify "$1" --title "Remote" >/dev/null 2>&1 || printf '%s\n' "$1" >&2
}

# an error has to land where the key was pressed. A desktop banner is easy to
# miss, and missing it makes a failed chord look like a chord that did nothing,
# so a failure goes to the session as a HUD panel: passive, so the terminal
# underneath keeps taking keystrokes, and closed by a child that outlives this
# script. A tty means someone typed the command and can read stderr; an
# emptied window has no session to post to, and falls back to the banner.
report() {
	msg=$1
	detail=${2:-}
	if [ -t 2 ]; then
		printf '%s\n' "$msg${detail:+: $detail}" >&2
		return
	fi
	target=${AGT_SESSION_ID:-${AGTERM_SESSION_ID:-active}}
	# a shell has no arrays, and an unquoted ${detail:+--detail "$detail"} would
	# split a detail that holds spaces into several arguments
	if [ -n "$detail" ]; then
		set -- --detail "$detail"
	else
		set --
	fi
	if agt session hud open "$msg" "$@" --position top-center \
		--text-color '#ff6b6b' --target "$target" >/dev/null 2>&1; then
		(sleep 8; agt session hud close --target "$target" >/dev/null 2>&1) &
		return
	fi
	notify "$msg${detail:+: $detail}"
}

fail() {
	report "$1" "${2:-}"
	exit 1
}

# a name becomes a tmux session, a file name and an argv word, so it is validated
# rather than trusted; a project additionally allows dots for repositories that
# carry them.
valid_name() { printf '%s' "$1" | grep -Eqx '[A-Za-z0-9_-]{1,64}'; }
valid_project() { printf '%s' "$1" | grep -Eqx '[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}'; }

canonical_id() {
	printf '%s' "$1" | tr '[:lower:]' '[:upper:]' |
		grep -Ex '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
}

# the status bridge's port on the host: a fresh one per connection, because a
# reattach that takes a session over from another tab would otherwise ask for
# the port that tab still holds. The host learns it from the attach line.
random_port() {
	printf '%d\n' $((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 20000))
}

# the host script reads the projects root from its environment, and ssh forwards
# none, so the local config's value rides on the remote command line
remote() {
	ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "AGT_REMOTE_PROJECTS='$PROJECTS' $REMOTE_BIN $*"
}

require_host() {
	[ -n "$HOST" ] || fail "AGT_REMOTE_HOST is not set; see $CONFIG"
	case $PROJECTS$COMMAND$REMOTE_BIN in
	*"'"*) fail "AGT_REMOTE_PROJECTS, AGT_REMOTE_COMMAND and AGT_REMOTE_BIN may not contain a single quote" ;;
	esac
}

# `tree` reports one window; the tab may be in another, so walk them all
session_name() {
	windows=$(agt window list --json) || return 1
	ids=$(printf '%s' "$windows" | jq -r '.result.windows[] | select(.open) | .id') || return 1
	for w in $ids; do
		tree=$(agt tree --window "$w" --json) || return 1
		n=$(printf '%s' "$tree" | jq -r --arg s "$1" '
			(.result.tree.workspaces // [])[].sessions[]?
			| select((.id | ascii_upcase) == $s)
			| .name // empty') || return 1
		if [ -n "$n" ]; then
			printf '%s\n' "$n"
			return 0
		fi
	done
	return 0
}

# ---------------------------------------------------------------- open

open() {
	require_host
	command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"

	# one round trip lists sessions and projects; the host script prints TSV
	listing=$(remote list 2>&1)
	rc=$?
	# 255 is ssh's own failure, the host being down or unreachable among them, and
	# the last line carries which. Anything else came from the host script.
	if [ "$rc" -eq 255 ]; then
		fail "$HOST is unreachable" "$(printf '%s\n' "$listing" | tail -1)"
	elif [ "$rc" -ne 0 ]; then
		fail "cannot list $HOST" "$(printf '%s\n' "$listing" | tail -1)"
	fi

	# stderr rides along so a failure has something to report, and an ordinary host
	# writes plenty of it: a locale warning, a Banner, an echo in a startup file.
	# Only a well-formed row becomes an item; the rest would carry a null label.
	items=$(printf '%s\n' "$listing" | jq -R -s --arg badge "$BADGE" '
		split("\n") | map(select(length > 0) | split("\t"))
		| map(select((.[0] == "S" and length == 4) or (.[0] == "P" and length == 3)))
		| map(
			if .[0] == "S" then
				{id: ("s:" + .[1]), label: ($badge + .[1]),
				 subtitle: ((if .[2] == "0" then "detached" else "attached" end) + " · " + .[3])}
			else
				{id: ("p:" + .[1]), label: .[1], subtitle: ("new session in " + .[2])}
			end)') || fail "cannot parse the listing from $HOST"

	# an empty picker is refused by pick.open, so the first open on a host with no
	# project yet would report the refusal rather than the reason for it
	[ "$(printf '%s' "$items" | jq 'length')" -gt 0 ] ||
		fail "no sessions or projects on $HOST yet: clone one with '$(basename "$SELF") clone URL'"

	choice=$(printf '%s' "$items" | agt pick --prompt "remote session or project" --window "${window:-active}")
	rc=$?
	case $rc in
	0) ;;
	2) exit 0 ;;
	*) fail "picker failed (exit $rc)" ;;
	esac
	id=$(printf '%s' "$choice" | jq -r '.id')

	case $id in
	s:*)
		name=${id#s:}
		project=$(printf '%s\n' "$listing" | awk -F '\t' -v n="$name" '$1 == "S" && $2 == n { print $4; exit }')
		;;
	p:*)
		project=${id#p:}
		# an empty list with --allow-custom is a plain text prompt
		answer=$(agt pick --prompt "session name" --query "$project" --allow-custom \
			--window "${window:-active}" </dev/null)
		rc=$?
		case $rc in
		0) ;;
		2) exit 0 ;;
		*) fail "picker failed (exit $rc)" ;;
		esac
		name=$(printf '%s' "$answer" | jq -r '.query // .id' | tr ' ' '-')
		;;
	*) fail "unexpected pick: $id" ;;
	esac

	valid_name "$name" || fail "not a usable session name: '$name' (letters, digits, - and _)"
	valid_project "$project" || fail "not a usable project name: '$project'"

	# an already-open tab for this session is reused, not doubled
	if [ -f "$STATE_DIR/index/$name" ]; then
		existing=$(cat "$STATE_DIR/index/$name")
		if [ -n "$(session_name "$existing")" ]; then
			agt session select --target "$existing" >/dev/null 2>&1 && exit 0
		fi
	fi

	cwd=$HOME
	[ -d "$LOCAL_PROJECTS/$project" ] && cwd=$LOCAL_PROJECTS/$project

	# --command is tokenized argv-style, quotes respected; the restore line is
	# typed into a shell. The same quoting serves both.
	run="'$SELF' attach $name $project"
	out=$(agt session new --cwd "$cwd" --workspace-name "$project" --create-workspace \
		--name "$BADGE$name" --command "$run" \
		--window "${window:-active}" --json) || fail "session new failed: $out"
	sid=$(printf '%s' "$out" | jq -r '.result.id')
	[ -n "$sid" ] || fail "session new returned no id"

	# the tab reattaches on its own after an agterm restart: a pinned line rather
	# than the captured foreground, which would replay a bare ssh with no loop.
	if ! agt session restore "$run" --target "$sid" >/dev/null 2>&1; then
		notify "$name opened, but its reconnect line could not be pinned: after an agterm restart run: $run"
	else
		# the pin replays under Re-run commands or Live sessions only, and Fresh
		# shells is the default, so a setting loses the reattach more often than a
		# failure does. Best-effort: `restore mode` is newer than 0.22.0.
		case $(agt restore mode --json 2>/dev/null | jq -r '.result.restore.configured // empty' 2>/dev/null) in
		none) notify "$name opened, but Settings ▸ General ▸ Sessions is on Fresh shells: after an agterm restart the tab comes back as a plain shell" ;;
		esac
	fi

	mkdir -p "$STATE_DIR/index"
	printf '%s\t%s\n' "$name" "$project" >"$STATE_DIR/$(canonical_id "$sid")"
	printf '%s\n' "$sid" >"$STATE_DIR/index/$name"
}

# ---------------------------------------------------------------- attach

attach() {
	name=$1
	project=$2
	valid_name "$name" || fail "not a usable session name: '$name'"
	valid_project "$project" || fail "not a usable project name: '$project'"
	[ -n "$HOST" ] || {
		printf 'AGT_REMOTE_HOST is not set; see %s\n' "$CONFIG" >&2
		exec "${SHELL:-/bin/sh}" -l
	}
	require_host
	bridge=0
	relay_pid=""
	relay_dir=""
	relay_sock=""

	# the status bridge: a relay on this side owns the tab's target and accepts
	# nothing but a status, so the host never sees the control socket itself.
	# Its socket sits in a fresh private directory per attach, made atomically
	# under a name nobody can predict: /tmp is shared, so a fixed path there
	# could be pre-created by another user, and unix socket paths cap near 104
	# bytes, which rules out $TMPDIR. One socket per attach also means a tab
	# taking the session over on this same Mac never shares a path with the
	# relay it replaces.
	if [ "$STATUS" = 1 ] && [ -n "$socket" ] && [ -n "${AGTERM_SESSION_ID:-}" ]; then
		if ! command -v python3 >/dev/null 2>&1; then
			printf '[%s] no python3 on this Mac; statuses stay idle\n' "$name"
		elif ! relay_dir=$(mktemp -d /tmp/agt-remote.XXXXXXXX); then
			relay_dir=""
			printf '[%s] no private directory for the status relay; statuses stay idle\n' "$name"
		else
			relay_sock=$relay_dir/$name.sock
			python3 "$(dirname "$SELF")/agt-remote-relay.py" --listen "$relay_sock" --agterm "$socket" \
				--target "$AGTERM_SESSION_ID" --pane "${AGTERM_PANE:-}" --pane-id "${AGTERM_PANE_ID:-}" &
			relay_pid=$!
			i=0
			while [ ! -S "$relay_sock" ] && [ "$i" -lt 20 ]; do
				sleep 0.1
				i=$((i + 1))
			done
			if [ -S "$relay_sock" ]; then
				bridge=1
			else
				kill "$relay_pid" 2>/dev/null
				relay_pid=""
				printf '[%s] status bridge did not start; the row will stay idle\n' "$name"
			fi
		fi
	fi

	# Ctrl-C while reconnecting stops the loop and leaves a local shell in the tab
	stop=0
	trap 'stop=1' INT

	while [ "$stop" -eq 0 ]; do
		# the forward is established on its own first: a short connection that
		# asks for the same -R and nothing else proves the host accepts it and the
		# port is free, before any attach runs. Three ports refused while a plain
		# connection works is the host refusing -R, and the session then opens
		# without its bridge rather than never. Its own connection, not the
		# shared master, so the probe's forward goes away with it.
		port=""
		if [ "$bridge" -eq 1 ]; then
			tries=0
			while [ -z "$port" ] && [ "$tries" -lt 3 ]; do
				candidate=$(random_port)
				if ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlPath=none -o ExitOnForwardFailure=yes \
					-R "127.0.0.1:$candidate:$relay_sock" "$HOST" true 2>/dev/null; then
					port=$candidate
				else
					tries=$((tries + 1))
				fi
			done
			if [ -z "$port" ]; then
				if ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null; then
					bridge=0
					[ -n "$relay_pid" ] && kill "$relay_pid" 2>/dev/null
					relay_pid=""
					printf '\n[%s] the host refused the status forward; continuing without statuses\n' "$name"
				else
					printf '\n[%s] host unreachable, retrying in %ss (Ctrl-C for a local shell)\n' "$name" "$RETRY"
					i=0
					while [ "$i" -lt "$RETRY" ] && [ "$stop" -eq 0 ]; do
						sleep 1
						i=$((i + 1))
					done
				fi
				continue
			fi
		fi

		# ssh joins its arguments with spaces into one remote line, so an empty one
		# would vanish and shift the rest; every word is quoted for the remote shell
		line="AGT_REMOTE_PROJECTS='$PROJECTS' $REMOTE_BIN attach '$name' '$project' '$port' '$COMMAND'"
		if [ -n "$port" ]; then
			ssh -t -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ExitOnForwardFailure=yes \
				-R "127.0.0.1:$port:$relay_sock" "$HOST" "$line"
		else
			ssh -t -o ServerAliveInterval=15 -o ServerAliveCountMax=4 "$HOST" "$line"
		fi
		rc=$?
		# a forward asked for by a multiplexed client outlives that client: nothing
		# else cancels it, so every reopen would leave a listener on the host until
		# the shared master goes. Quiet when there is no master to ask.
		[ -n "$port" ] && ssh -O cancel -R "127.0.0.1:$port:$relay_sock" "$HOST" >/dev/null 2>&1
		case $rc in
		0) break ;;
		255)
			# a dropped connection, or the rare port taken between probe and attach:
			# the tmux session is still there, so come back, probing afresh
			printf '\n[%s] connection lost, reconnecting in %ss (Ctrl-C for a local shell)\n' "$name" "$RETRY"
			i=0
			while [ "$i" -lt "$RETRY" ] && [ "$stop" -eq 0 ]; do
				sleep 1
				i=$((i + 1))
			done
			;;
		*)
			printf '\n[%s] remote command exited with %s\n' "$name" "$rc"
			break
			;;
		esac
	done
	trap - INT

	# exec keeps this pid, so the relay's parent check would never fire: stop it here
	[ -n "$relay_pid" ] && kill "$relay_pid" 2>/dev/null
	[ -n "$relay_dir" ] && rm -rf "$relay_dir"
	rm -f "$STATE_DIR/index/$name"
	printf '[%s] detached; "%s attach %s %s" reattaches\n' "$name" "$SELF" "$name" "$project"
	exec "${SHELL:-/bin/sh}" -l
}

# ---------------------------------------------------------------- end

end() {
	require_host
	command -v jq >/dev/null 2>&1 || fail "jq is not on PATH"
	sid=$(canonical_id "${1:-${AGT_SESSION_ID:-${AGTERM_SESSION_ID:-}}}") || fail "not a session id: '${1:-}'"

	name=""
	project=""
	if [ -f "$STATE_DIR/$sid" ]; then
		name=$(cut -f1 "$STATE_DIR/$sid")
		project=$(cut -f2 "$STATE_DIR/$sid")
	fi
	# no marker (the tab came from another machine's state): the badge names it
	if [ -z "$name" ] && [ -n "$BADGE" ]; then
		label=$(session_name "$sid") || fail "cannot reach agterm"
		case $label in
		"$BADGE"*) name=${label#"$BADGE"} ;;
		esac
	fi
	[ -n "$name" ] || fail "this tab is not a remote session"
	valid_name "$name" || fail "not a usable session name: '$name'"

	# Return on open keeps the session; killing takes a deliberate choice
	answer=$(printf '[{"id":"keep","label":"Leave %s running"},{"id":"kill","label":"Kill %s on %s","subtitle":"tmux kill-session: the agent and everything in it stops, then this tab closes"}]' \
		"$name" "$name" "$HOST" | agt pick --prompt "end remote session?" --window "${window:-active}")
	rc=$?
	[ "$rc" -eq 0 ] || exit 0
	[ "$(printf '%s' "$answer" | jq -r '.id')" = "kill" ] || exit 0

	out=$(remote kill "$name" 2>&1) || fail "could not kill $name on $HOST" "$(printf '%s\n' "$out" | tail -1)"
	rm -f "$STATE_DIR/$sid" "$STATE_DIR/index/$name"
	agt session close --target "$sid" >/dev/null 2>&1 || notify "$name killed on $HOST; close the tab by hand"
}

# ---------------------------------------------------------------- install

install() {
	require_host
	src=$(dirname "$SELF")/agt-remote-host.sh
	[ -f "$src" ] || fail "agt-remote-host.sh is not beside $SELF"
	[ -f "$(dirname "$SELF")/agt-remote-relay.py" ] || fail "agt-remote-relay.py is not beside $SELF"
	dir=$(dirname "$REMOTE_BIN")
	# shellcheck disable=SC2029 # the paths are meant to expand here, for the host's shell
	ssh "$HOST" "mkdir -p '$dir' && cat > '$REMOTE_BIN' && chmod +x '$REMOTE_BIN'" <"$src" ||
		fail "could not copy the host script to $HOST"
	# tmux refuses to start under a TERM the host has no terminfo for
	if [ -n "${TERM:-}" ] && infocmp -x "$TERM" >/dev/null 2>&1; then
		infocmp -x "$TERM" | ssh "$HOST" "tic -x - 2>/dev/null || true"
	fi
	# the forges' host keys travel from this Mac's known_hosts, which has already
	# verified them, rather than being scanned and trusted on the host blind
	{
		for h in github.com gitlab.com; do
			ssh-keygen -F "$h" -f "$HOME/.ssh/known_hosts" 2>/dev/null | grep -v '^#'
		done
	} | remote setup
}

# the token is read here and travels on stdin, so it never sits in a process
# list or a shell history on either side. There is deliberately no argument
# form: taking one is what would put a long-lived credential in both.
auth() {
	require_host
	token=""
	if [ -t 0 ]; then
		printf 'paste the token from "claude setup-token": '
		# a Ctrl-C on the prompt must not leave the terminal with echo off
		tty_state=$(stty -g 2>/dev/null)
		trap 'stty "$tty_state" 2>/dev/null; exit 130' INT TERM
		stty -echo 2>/dev/null
		IFS= read -r token
		stty "$tty_state" 2>/dev/null
		trap - INT TERM
		printf '\n'
	else
		IFS= read -r token
	fi
	[ -n "$token" ] || fail "no token given"
	printf '%s' "$token" | grep -Eqx '[A-Za-z0-9_-]+' || fail "that does not look like a token"
	printf '%s\n' "$token" | ssh -o BatchMode=yes "$HOST" "AGT_REMOTE_PROJECTS='$PROJECTS' $REMOTE_BIN auth"
}

# -A: the clone authenticates with the keys in this Mac's agent, so the host
# holds no deploy key of its own
clone() {
	require_host
	url=$1
	name=${2:-}
	case $url$name in
	*"'"*) fail "the URL and name may not contain a single quote" ;;
	esac
	ssh -A -o BatchMode=yes "$HOST" "AGT_REMOTE_PROJECTS='$PROJECTS' $REMOTE_BIN clone '$url' '$name'"
}

sync_claude() {
	require_host
	command -v rsync >/dev/null 2>&1 || fail "rsync is not on PATH"
	for item in CLAUDE.md skills agents commands; do
		[ -e "$HOME/.claude/$item" ] || continue
		rsync -a --delete "$HOME/.claude/$item" "$HOST:.claude/" || fail "rsync of $item failed"
		echo "synced ~/.claude/$item"
	done
}

cmd=${1:-}
case $cmd in
open) open ;;
attach) attach "${2:?name}" "${3:?project}" ;;
end) end "${2:-}" ;;
list) require_host && remote list ;;
install) install ;;
auth) [ $# -eq 1 ] || fail "auth takes no arguments; it reads the token from a prompt or stdin"
	auth ;;
clone) clone "${2:?url}" "${3:-}" ;;
sync) sync_claude ;;
*)
	echo "usage: ${0##*/} open | attach NAME PROJECT | end [SESSION-ID] | list | install | auth | clone URL [NAME] | sync" >&2
	exit 2
	;;
esac
