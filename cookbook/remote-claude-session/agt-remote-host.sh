#!/usr/bin/env bash
# agt-remote-host.sh - the host half of agt-remote.sh. Lives on the remote
# machine; agt-remote.sh calls it over ssh. See README.md.
#
#   attach NAME PROJECT [SID PANE PANE_ID PORT] [CMD]
#                    create the tmux session, start CMD in it on first creation,
#                    record where its statuses go, and attach
#   status STATE [--blink] [--auto-reset]
#                    an agent hook: post STATE to the agterm tab attached here
#   list             sessions and projects as TSV, for the picker
#   kill NAME        end a session (DESTRUCTIVE: everything in it dies)
#   setup            one-time host preparation, run by `agt-remote.sh install`
#   hooks            print the Claude Code hooks block to merge
set -u

STATE=${AGT_REMOTE_STATE:-$HOME/.agt-remote}
PROJECTS=${AGT_REMOTE_PROJECTS:-$HOME/projects}
PROJECTS=${PROJECTS/#\~/$HOME}
[[ $PROJECTS == /* ]] || PROJECTS=$HOME/$PROJECTS

valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }

# ---------------------------------------------------------------- attach

attach() {
	local name=$1 project=$2 sid=${3:-} pane=${4:-} pane_id=${5:-} port=${6:-} cmd=${7:-claude}
	valid_name "$name" || { echo "bad session name: $name" >&2; exit 2; }
	local dir=$PROJECTS/$project
	[[ -d $dir ]] || { echo "no such project on $(hostname): $dir" >&2; exit 2; }

	mkdir -p "$STATE"
	# where this session's statuses go: rewritten on every attach, so a tab
	# opened later, or after an agterm restart, is the one that lights up
	if [[ -n $sid && -n $port ]]; then
		printf '%s\t%s\t%s\t%s\n' "$port" "$sid" "$pane" "$pane_id" >"$STATE/$name.target"
	else
		rm -f "$STATE/$name.target"
	fi

	# a TERM the host cannot name makes tmux refuse to start
	infocmp "${TERM:-}" >/dev/null 2>&1 || export TERM=xterm-256color

	if ! tmux has-session -t "=$name" 2>/dev/null; then
		tmux new-session -d -s "$name" -c "$dir" || exit 1
		# the agent's conversation id is pinned to the session name, so a host
		# reboot brings back the same conversation rather than a new one
		local idfile=$STATE/$name.claude id
		if [[ -f $idfile ]]; then
			id=$(<"$idfile")
		else
			id=$(uuidgen | tr '[:upper:]' '[:lower:]')
			printf '%s\n' "$id" >"$idfile"
		fi
		local transcripts=("$HOME"/.claude/projects/*/"$id".jsonl)
		if [[ -f ${transcripts[0]} ]]; then
			tmux send-keys -t "=$name" "$cmd --resume $id" Enter
		else
			tmux send-keys -t "=$name" "$cmd --session-id $id" Enter
		fi
	fi
	# -d: the last client wins, so a tab forgotten elsewhere cannot shrink this one
	exec tmux attach-session -d -t "=$name"
}

# ---------------------------------------------------------------- status

# runs as an agent hook inside the tmux session; never fails, never prints
status() {
	local state=${1:-} blink=false reset=false name target
	shift || true
	for a in "$@"; do
		case $a in
		--blink) blink=true ;;
		--auto-reset) reset=true ;;
		esac
	done
	[[ -n $state && -n ${TMUX:-} ]] || return 0
	name=$(tmux display-message -p '#S' 2>/dev/null) || return 0
	target=$STATE/$name.target
	[[ -f $target ]] || return 0
	python3 - "$state" "$blink" "$reset" "$target" <<-'EOF' 2>/dev/null || true
		import json, socket, sys
		state, blink, reset = sys.argv[1], sys.argv[2] == "true", sys.argv[3] == "true"
		with open(sys.argv[4]) as f:
		    fields = f.readline().rstrip("\n").split("\t") + ["", "", "", ""]
		port, sid, pane, pane_id = fields[0], fields[1], fields[2], fields[3]
		args = {"status": state}
		if blink: args["blink"] = True
		if reset: args["autoReset"] = True
		if pane: args["pane"] = pane
		if pane_id: args["paneID"] = pane_id
		req = {"cmd": "session.status", "target": sid, "args": args}
		with socket.create_connection(("127.0.0.1", int(port)), timeout=2) as s:
		    s.sendall((json.dumps(req) + "\n").encode())
		    s.recv(4096)
	EOF
	return 0
}

# ---------------------------------------------------------------- list, kill

list() {
	tmux list-sessions -F $'S\t#{session_name}\t#{session_attached}\t#{b:session_path}' 2>/dev/null |
		sort -t $'\t' -k2
	local d
	for d in "$PROJECTS"/*/; do
		[[ -d $d ]] || continue
		d=${d%/}
		printf 'P\t%s\t%s\n' "${d##*/}" "$d"
	done
}

kill_session() {
	local name=$1
	valid_name "$name" || { echo "bad session name: $name" >&2; exit 2; }
	tmux kill-session -t "=$name" 2>/dev/null || true
	rm -f "$STATE/$name.target" "$STATE/$name.claude"
}

# ---------------------------------------------------------------- setup, hooks

setup() {
	mkdir -p "$STATE" "$PROJECTS"
	local conf=$HOME/.tmux.conf
	# OSC 52 (clipboard) and OSC 9/777 (notifications) from the agent have to
	# pass through tmux to reach the terminal on the other side of ssh
	grep -qs 'agt-remote' "$conf" || cat >>"$conf" <<-'EOF'
		# agt-remote: let the agent's clipboard and notification escapes through
		set -g set-clipboard on
		set -g allow-passthrough on
		set -g history-limit 50000
	EOF
	command -v tmux >/dev/null || echo "tmux is not installed" >&2
	command -v python3 >/dev/null || echo "python3 is not installed (the status bridge needs it)" >&2
	command -v uuidgen >/dev/null || echo "uuidgen is not installed" >&2
	echo "host ready: projects in $PROJECTS, state in $STATE"
	echo "merge the hooks block into ~/.claude/settings.json: $0 hooks"
}

hooks() {
	local me
	me=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	cat <<-EOF
		{
		  "hooks": {
		    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$me status active --blink" }] }],
		    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "$me status active --blink" }] }],
		    "Stop":             [{ "hooks": [{ "type": "command", "command": "$me status completed --auto-reset" }] }],
		    "Notification":     [{ "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "$me status blocked" }] }]
		  }
		}
	EOF
}

case ${1:-} in
attach) attach "${2:?name}" "${3:?project}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-claude}" ;;
status) shift; status "$@" ;;
list) list ;;
kill) kill_session "${2:?name}" ;;
setup) setup ;;
hooks) hooks ;;
*)
	echo "usage: ${0##*/} attach NAME PROJECT [SID PANE PANE_ID PORT] [CMD] | status STATE [--blink] [--auto-reset] | list | kill NAME | setup | hooks" >&2
	exit 2
	;;
esac
