#!/usr/bin/env python3
"""agt-remote-relay.py - the Mac end of the status bridge, started by agt-remote.sh attach.

Listens on a unix socket that `ssh -R` forwards to the host, accepts only a
`session.status` request, rebuilds it with this tab's fixed target and pane, and
sends that to agterm's control socket. The host never reaches the socket itself:
a request for any other command, target or field is answered `refused` and dropped.

Exits on its own when the parent attach loop is gone, so a hard-killed agterm
leaves no relay behind.
"""

import argparse
import json
import os
import signal
import socket
import sys

STATES = {"idle", "active", "completed", "blocked"}
LINE_CAP = 4096
REFUSED = b'{"ok":false,"error":"refused"}\n'


def read_line(conn):
    data = b""
    while b"\n" not in data and len(data) < LINE_CAP:
        chunk = conn.recv(1024)
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0]


def clean_request(raw, opts):
    req = json.loads(raw.decode("utf-8"))
    if not isinstance(req, dict) or req.get("cmd") != "session.status":
        raise ValueError("not a status request")
    args = req.get("args")
    if not isinstance(args, dict) or args.get("status") not in STATES:
        raise ValueError("bad status")
    clean = {"status": args["status"]}
    if args.get("blink") is True:
        clean["blink"] = True
    if args.get("autoReset") is True:
        clean["autoReset"] = True
    if opts.pane:
        clean["pane"] = opts.pane
    if opts.pane_id:
        clean["paneID"] = opts.pane_id
    return {"cmd": "session.status", "target": opts.target, "args": clean}


def forward(req, agterm_socket):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(3)
        s.connect(agterm_socket)
        s.sendall(json.dumps(req).encode("utf-8") + b"\n")
        resp = json.loads(read_line(s).decode("utf-8"))
    return resp.get("ok") is True


def serve(conn, opts):
    conn.settimeout(3)
    try:
        ok = forward(clean_request(read_line(conn), opts), opts.agterm)
        reply = b'{"ok":true}\n' if ok else b'{"ok":false}\n'
    except Exception:  # noqa: BLE001 - any bad input or a dead socket is one answer: refused
        reply = REFUSED
    try:
        conn.sendall(reply)
    except OSError:
        pass


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--listen", required=True, help="unix socket to serve, forwarded by ssh -R")
    p.add_argument("--agterm", required=True, help="agterm's control socket")
    p.add_argument("--target", required=True, help="the session id every status lands on")
    p.add_argument("--pane", default="")
    p.add_argument("--pane-id", default="")
    opts = p.parse_args()

    # the attach loop stops the relay with SIGTERM; turn it into a normal exit so
    # the socket file is removed below
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    parent = os.getppid()
    try:
        os.unlink(opts.listen)
    except FileNotFoundError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)
    try:
        srv.bind(opts.listen)
    finally:
        os.umask(old)
    srv.listen(8)
    srv.settimeout(5)
    own_inode = os.stat(opts.listen).st_ino
    try:
        while os.getppid() == parent:
            try:
                conn, _ = srv.accept()
            # not TimeoutError: the two are one class only from 3.10, and the
            # /usr/bin/python3 this runs on is 3.9, where accept() raises this one
            except socket.timeout:  # noqa: UP041
                continue
            with conn:
                serve(conn, opts)
    finally:
        srv.close()
        # only this relay's own socket: a newer relay may have taken the path
        try:
            if os.stat(opts.listen).st_ino == own_inode:
                os.unlink(opts.listen)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
