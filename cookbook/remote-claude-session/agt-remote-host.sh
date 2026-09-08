#!/usr/bin/env bash
# agt-remote-host.sh - the host half of agt-remote.sh. Lives on the remote
# machine; agt-remote.sh calls it over ssh. See README.md.
#
#   attach NAME PROJECT [PORT] [CMD]
#                    create the tmux session, start CMD in it on first creation,
#                    record the port its statuses go to, and attach
#   status STATE [--blink] [--auto-reset]
#                    an agent hook: post STATE to the agterm tab attached here
#   list             sessions and projects as TSV, for the picker
#   kill NAME        end a session (DESTRUCTIVE: everything in it dies)
#   setup            host preparation, run by `agt-remote.sh install`; idempotent
#   auth             store the agent's OAuth token from stdin for every session
#   clone URL [NAME] clone a repository under the projects root
#   hooks            print the Claude Code hooks block setup merges
set -u

STATE=${AGT_REMOTE_STATE:-$HOME/.agt-remote}
PROJECTS=${AGT_REMOTE_PROJECTS:-$HOME/projects}
PROJECTS=${PROJECTS/#\~/$HOME}
[[ $PROJECTS == /* ]] || PROJECTS=$HOME/$PROJECTS
PROJECTS=${PROJECTS%/}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

valid_name() { [[ $1 =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }
valid_project() { [[ $1 =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$ ]]; }

# ---------------------------------------------------------------- attach

attach() {
	local name=$1 project=$2 port=${3:-} cmd=${4:-claude}
	valid_name "$name" || { echo "bad session name: $name" >&2; exit 2; }
	valid_project "$project" || { echo "bad project name: $project" >&2; exit 2; }
	[[ $cmd$STATE != *"'"* ]] || { echo "the command and state path may not contain a single quote" >&2; exit 2; }
	local dir=$PROJECTS/$project
	[[ -d $dir ]] || { echo "no such project on $(hostname): $dir" >&2; exit 2; }

	mkdir -p "$STATE"
	# the port this session's statuses go to: rewritten on every attach, so a
	# tab opened later, or after an agterm restart, is the one that lights up.
	# The relay on the Mac side owns the target; nothing about it is stored here.
	if [[ $port =~ ^[0-9]{1,5}$ ]]; then
		printf '%s\n' "$port" >"$STATE/$name.target"
	else
		rm -f "$STATE/$name.target"
	fi

	# a TERM the host cannot name makes tmux refuse to start
	infocmp "${TERM:-}" >/dev/null 2>&1 || export TERM=xterm-256color

	# the forwarded agent reaches this session through a link of its own, repointed
	# on every attach. One shared path would be rewritten by every other ssh command
	# to this host, since sshd runs ~/.ssh/rc for each of them, and a short one that
	# exits leaves it pointing at a socket that is gone: git in every live session
	# then breaks until the next attach.
	local agent=$STATE/$name.agent.sock
	if [[ -S ${SSH_AUTH_SOCK:-} ]] && ! ln -sfn "$SSH_AUTH_SOCK" "$agent"; then
		echo "could not point $agent at the forwarded agent; git in this session will not sign" >&2
	fi

	if ! tmux has-session -t "=$name" 2>/dev/null; then
		# the pane's own id: send-keys takes a target-pane, where the exact-match
		# prefix that addresses a session resolves to nothing, and the command that
		# starts the agent would be dropped with the session left at a bare prompt
		local pane
		pane=$(tmux new-session -d -P -F '#{pane_id}' -s "$name" -c "$dir") || exit 1
		# the agent's conversation id is pinned to the session name, so a host
		# reboot brings back the same conversation rather than a new one
		local idfile=$STATE/$name.claude id
		if [[ -f $idfile ]]; then
			id=$(<"$idfile")
		else
			id=$(uuidgen | tr '[:upper:]' '[:lower:]')
			printf '%s\n' "$id" >"$idfile"
		fi
		local transcripts=("$HOME"/.claude/projects/*/"$id".jsonl) flag=--session-id
		[[ -f ${transcripts[0]} ]] && flag=--resume
		# the token `auth` stored is read by a wrapper inside the session, so it
		# never appears on a command line and does not depend on which startup
		# file the login shell reads; `sh` keeps this the same under any shell.
		# The file is optional: a host signed in interactively has none.
		tmux send-keys -t "$pane" \
			"sh -c '[ -f \"$STATE/env\" ] && . \"$STATE/env\"; SSH_AUTH_SOCK=\"$agent\"; export SSH_AUTH_SOCK; exec $cmd $flag $id'" Enter ||
			{ tmux kill-session -t "=$name" 2>/dev/null; exit 1; }
	fi
	# the pane above carries the link in its own environment; this is for the windows
	# opened in the session later, which take theirs from the session
	tmux set-environment -t "=$name" SSH_AUTH_SOCK "$agent" 2>/dev/null || true
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
		    port = int(f.readline().strip())
		args = {"status": state}
		if blink: args["blink"] = True
		if reset: args["autoReset"] = True
		req = {"cmd": "session.status", "args": args}
		with socket.create_connection(("127.0.0.1", port), timeout=2) as s:
		    s.sendall((json.dumps(req) + "\n").encode())
		    s.recv(4096)
	EOF
	return 0
}

# ---------------------------------------------------------------- list, kill

list() {
	# only sessions sitting directly in a project directory: the host's own tmux
	# sessions are not this recipe's, and picking one would end in a failed attach
	local name attached path
	while IFS=$'\t' read -r name attached path; do
		[[ $path == "$PROJECTS"/* && ${path#"$PROJECTS"/} != */* ]] || continue
		printf 'S\t%s\t%s\t%s\n' "$name" "$attached" "${path##*/}"
	done < <(tmux list-sessions -F $'#{session_name}\t#{session_attached}\t#{session_path}' 2>/dev/null) |
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
	rm -f "$STATE/$name.target" "$STATE/$name.claude" "$STATE/$name.agent.sock"
}

# ---------------------------------------------------------------- setup

# an append to a file whose last line has no newline glues onto it, and the
# known_hosts entry glued that way never matches on a rerun and is added again
end_newline() {
	[[ -s $1 && -n $(tail -c1 "$1") ]] && printf '\n' >>"$1"
	return 0
}

# every step checks for its own marker first, so a rerun changes nothing
setup() {
	mkdir -p "$STATE" "$PROJECTS" "$HOME/.ssh" "$HOME/.claude"
	chmod 700 "$HOME/.ssh"

	# OSC 52 (clipboard) and OSC 9/777 (notifications) from the agent have to
	# pass through tmux to reach the terminal on the other side of ssh. Nothing
	# here touches SSH_AUTH_SOCK: each session gets its own link, see attach.
	local conf=$HOME/.tmux.conf
	if ! grep -qs 'agt-remote' "$conf"; then
		end_newline "$conf"
		cat >>"$conf" <<-'EOF'
			# agt-remote: let the agent's clipboard and notification escapes through
			set -g set-clipboard on
			set -g allow-passthrough on
			set -g history-limit 50000
		EOF
	fi

	# the token `auth` stores, and anything else the sessions should carry
	local profile=$HOME/.profile
	if ! grep -qs 'agt-remote' "$profile"; then
		end_newline "$profile"
		cat >>"$profile" <<-'EOF'
			# agt-remote: the agent's credentials and session environment
			[ -f "$HOME/.agt-remote/env" ] && . "$HOME/.agt-remote/env"
		EOF
	fi

	# clones must not stop at a host-key prompt nobody can answer: the entries
	# arrive on stdin from the Mac's own known_hosts, already verified there
	local kh=$HOME/.ssh/known_hosts line
	touch "$kh"
	chmod 600 "$kh"
	end_newline "$kh"
	while IFS= read -r line; do
		[[ -n $line && $line != \#* ]] || continue
		grep -qxF -- "$line" "$kh" || printf '%s\n' "$line" >>"$kh"
	done

	local hooks="hooks merged into ~/.claude/settings.json"
	merge_hooks || {
		hooks="hooks NOT merged"
		echo "hooks NOT merged; fix ~/.claude/settings.json and rerun install" >&2
	}
	command -v tmux >/dev/null || echo "tmux is not installed" >&2
	command -v python3 >/dev/null || echo "python3 is not installed (the status bridge needs it)" >&2
	command -v uuidgen >/dev/null || echo "uuidgen is not installed" >&2
	# a login shell, the kind tmux opens; ssh's own shell for `setup` is not one
	bash -lc 'command -v claude' >/dev/null 2>&1 || echo "claude is not on PATH for login shells" >&2
	echo "host ready: projects in $PROJECTS, state in $STATE, $hooks"
}

# adds the four status hooks to ~/.claude/settings.json, keeping everything
# already there. A file that is not a JSON object is left untouched and
# reported; a file that needs no change is not rewritten and not backed up;
# a symlinked file is rewritten at its target, so the link survives.
merge_hooks() {
	local settings=$HOME/.claude/settings.json
	python3 - "$settings" "$SELF" <<-'EOF'
		import json, os, shutil, sys, time
		me = sys.argv[2]
		# through any symlink: a dotfiles-managed settings.json keeps its link
		path = os.path.realpath(sys.argv[1])
		data, mode = {}, 0o600
		if os.path.exists(path):
		    mode = os.stat(path).st_mode & 0o777
		    try:
		        with open(path) as f:
		            data = json.load(f)
		    except (OSError, ValueError) as e:
		        sys.exit(f"{path} is not valid JSON, left as is: {e}")
		    if not isinstance(data, dict):
		        sys.exit(f"{path} is not a JSON object, left as is")
		hooks = data.setdefault("hooks", {})
		if not isinstance(hooks, dict):
		    sys.exit(f"{path}: 'hooks' is not an object, left as is")
		wanted = [
		    ("UserPromptSubmit", None, "active --blink"),
		    ("PostToolUse", None, "active --blink"),
		    ("Stop", None, "completed --auto-reset"),
		    ("Notification", "permission_prompt", "blocked"),
		]
		changed = False
		for event, matcher, state in wanted:
		    cmd = f"{me} status {state}"
		    groups = hooks.setdefault(event, [])
		    if any(h.get("command") == cmd for g in groups for h in g.get("hooks", [])):
		        continue
		    group = {"hooks": [{"type": "command", "command": cmd}]}
		    if matcher:
		        group["matcher"] = matcher
		    groups.append(group)
		    changed = True
		if not changed:
		    sys.exit(0)
		if os.path.exists(path):
		    shutil.copy2(path, f"{path}.bak-agt-remote-{int(time.time())}")
		tmp = path + ".tmp"
		fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
		with os.fdopen(fd, "w") as f:
		    json.dump(data, f, indent=2)
		    f.write("\n")
		os.chmod(tmp, mode)
		os.replace(tmp, path)
	EOF
}

hooks() {
	cat <<-EOF
		{
		  "hooks": {
		    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "$SELF status active --blink" }] }],
		    "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "$SELF status active --blink" }] }],
		    "Stop":             [{ "hooks": [{ "type": "command", "command": "$SELF status completed --auto-reset" }] }],
		    "Notification":     [{ "matcher": "permission_prompt", "hooks": [{ "type": "command", "command": "$SELF status blocked" }] }]
		  }
		}
	EOF
}

# ---------------------------------------------------------------- auth, clone

auth() {
	# the token file is created before it can be chmod'd, and a channel that drops
	# between the write and the rename leaves the temporary behind
	umask 077
	local token
	IFS= read -r token
	[[ $token =~ ^[A-Za-z0-9_-]+$ ]] || { echo "no usable token on stdin" >&2; exit 2; }
	mkdir -p "$STATE"
	local env=$STATE/env
	touch "$env"
	chmod 600 "$env"
	rm -f "$env.tmp"
	grep -v '^export CLAUDE_CODE_OAUTH_TOKEN=' "$env" >"$env.tmp" || true
	printf "export CLAUDE_CODE_OAUTH_TOKEN='%s'\n" "$token" >>"$env.tmp"
	chmod 600 "$env.tmp"
	mv "$env.tmp" "$env"
	echo "token stored in $env"
}

clone() {
	local url=$1 name=${2:-}
	# a URL that starts with a dash is an option to git, --upload-pack included
	[[ $url != -* ]] || { echo "bad URL: $url" >&2; exit 2; }
	[[ -n $name ]] || { name=${url##*/}; name=${name%.git}; }
	valid_project "$name" || { echo "bad project name: $name" >&2; exit 2; }
	mkdir -p "$PROJECTS"
	if [[ -d $PROJECTS/$name/.git ]]; then
		echo "$PROJECTS/$name already exists"
		return 0
	fi
	git clone -- "$url" "$PROJECTS/$name"
}

case ${1:-} in
attach) attach "${2:?name}" "${3:?project}" "${4:-}" "${5:-claude}" ;;
status) shift; status "$@" ;;
list) list ;;
kill) kill_session "${2:?name}" ;;
setup) setup ;;
auth) auth ;;
clone) clone "${2:?url}" "${3:-}" ;;
hooks) hooks ;;
*)
	echo "usage: ${0##*/} attach NAME PROJECT [PORT] [CMD] | status STATE [--blink] [--auto-reset] | list | kill NAME | setup | auth | clone URL [NAME] | hooks" >&2
	exit 2
	;;
esac
