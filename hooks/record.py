#!/usr/bin/env python3
"""Record the state of a local AI chat session, for the session switcher.

Called from Claude Code hooks and from Codex's `notify`. Both hand us JSON on
stdin (Claude) or as argv[1] (Codex); the event name comes from argv.

One file per session in ~/.local/state/chat-sessions/, holding just enough for
the switcher to draw a row and route a click:

    {"id", "tool", "cwd", "project", "state", "title", "updated", "pid",
     "term_program", "term_session", "window_title"}

`state` is one of: working, waiting, idle, done.
"""

import json
import os
import subprocess
import sys
import time

STATE_DIR = os.path.expanduser("~/.local/state/chat-sessions")

def own_only(path, mode):
    """Narrow a path to its owner.

    These records carry the opening lines of a conversation and the directory
    it runs in. The default 755/644 hands all of that to every other account
    on the machine, which is not what anyone means by a local session list.
    Best effort: a state directory on a volume with no POSIX modes is still
    worth writing to.
    """
    try:
        if os.path.exists(path) and (os.stat(path).st_mode & 0o777) != mode:
            os.chmod(path, mode)
    except OSError:
        pass


# Which hook means what. Anything unlisted just refreshes the timestamp.
STATES = {
    # A session that has just started is sitting at an empty prompt, not
    # working. Anything it goes on to do raises its own event.
    "SessionStart": "waiting",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "Stop": "waiting",
    "StopFailure": "waiting",
    "Notification": "waiting",
    "PermissionRequest": "waiting",
    "TeammateIdle": "waiting",
    "SubagentStart": "working",
    "SubagentStop": "working",
    "SessionEnd": "done",
    "turn-ended": "waiting",       # codex
    "agent-turn-complete": "waiting",
}


def read_payload():
    """Claude Code sends JSON on stdin; Codex passes it as an argument."""
    for arg in sys.argv[1:]:
        arg = arg.strip()
        if arg.startswith("{"):
            try:
                return json.loads(arg)
            except ValueError:
                pass
    if not sys.stdin.isatty():
        raw = sys.stdin.read().strip()
        if raw.startswith("{"):
            try:
                return json.loads(raw)
            except ValueError:
                pass
    return {}


def event_name():
    for arg in sys.argv[1:]:
        if arg in STATES:
            return arg
    return os.environ.get("CLAUDE_HOOK_EVENT", "")


def terminal_identity():
    """Whatever lets the switcher bring this session's window back up."""
    return {
        "term_program": os.environ.get("TERM_PROGRAM", ""),
        "term_session": os.environ.get("TERM_SESSION_ID", "")
                        or os.environ.get("ITERM_SESSION_ID", ""),
        "window_title": os.environ.get("WINDOW_TITLE", ""),
    }


def owning_app(pid):
    """Walk up the process tree to the app that owns this shell."""
    known = {"Terminal", "iTerm2", "Cursor", "Code", "Warp", "Alacritty",
             "kitty", "WezTerm", "Ghostty", "Hyper", "Electron"}
    current = pid
    for _ in range(12):
        try:
            out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(current)],
                                 capture_output=True, text=True, timeout=3).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""
        if not out:
            return ""
        parent, _, command = out.partition(" ")
        name = os.path.basename(command.strip()).replace(".app", "")
        for candidate in known:
            if candidate.lower() in name.lower():
                return candidate
        try:
            current = int(parent)
        except ValueError:
            return ""
        if current <= 1:
            return ""
    return ""


# Transcript directories the hooks have seen, shared with the scan.
KNOWN_ROOTS = os.path.join(STATE_DIR, "roots.json")


def register_home(tool, payload):
    """Note the transcript directory this session is writing to.

    Claude Code hands every hook a `transcript_path`; the directory holding
    the per-project folders is its parent's parent. Codex passes the rollout
    file the same way. Either way the path is the session's own, so no layout
    has to be guessed at.
    """
    raw = ""
    for key in ("transcript_path", "rollout_path", "rollout-path"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            raw = value.strip()
            break
    if not raw:
        return
    # <root>/<project folder>/<session>.jsonl
    root = os.path.dirname(os.path.dirname(os.path.realpath(os.path.expanduser(raw))))
    if not os.path.isdir(root):
        return

    try:
        with open(KNOWN_ROOTS) as fh:
            held = json.load(fh)
        if not isinstance(held, dict):
            held = {}
    except (IOError, OSError, ValueError):
        held = {}
    if root in held.get(tool, []):
        return
    held.setdefault(tool, []).append(root)
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        own_only(STATE_DIR, 0o700)
        tmp = KNOWN_ROOTS + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(held, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, KNOWN_ROOTS)
        own_only(KNOWN_ROOTS, 0o600)
    except OSError:
        pass


def main():
    payload = read_payload()
    event = event_name()
    state = STATES.get(event, "")

    tool = "codex" if event in ("turn-ended", "agent-turn-complete") else "claude"

    # Where this session's transcripts live. A hook runs inside the session,
    # so it knows; the scan has to guess at directory layouts and only knows
    # the arrangements someone thought to write down. Noting it here is what
    # lets a copy of the app nobody has heard of be picked up anyway.
    register_home(tool, payload)
    session_id = (payload.get("session_id") or payload.get("thread-id")
                  or payload.get("threadId") or os.environ.get("CLAUDE_SESSION_ID")
                  or "unknown")
    cwd = payload.get("cwd") or os.getcwd()

    # A subagent belongs to the session that spawned it. It gets no row of its
    # own: the parent is already marked working while the subagent runs.
    if session_id.startswith("agent-"):
        return 0

    os.makedirs(STATE_DIR, exist_ok=True)
    own_only(STATE_DIR, 0o700)
    path = os.path.join(STATE_DIR, "%s-%s.json" % (tool, session_id))

    if state == "done":
        try:
            os.remove(path)
        except OSError:
            pass
        return 0

    previous = {}
    try:
        with open(path) as fh:
            previous = json.load(fh)
    except (IOError, OSError, ValueError):
        pass

    title = (payload.get("last-assistant-message") or payload.get("prompt")
             or previous.get("title") or "")
    title = " ".join(title.split())[:120]

    # A run started by another agent rather than a person carries its brief as
    # a JSON object instead of a sentence. Left as it was, the row showed a
    # blob of syntax, or nothing at all and fell back to the folder name.
    chat = previous.get("chat") or ""
    origin = previous.get("origin") or ""
    if title.startswith("{"):
        origin = "agent"
    if not chat and title.startswith("{"):
        try:
            brief = json.loads(title)
        except ValueError:
            brief = None
        if isinstance(brief, dict):
            for key in ("description", "title", "task", "prompt"):
                value = brief.get(key)
                if isinstance(value, str) and value.strip():
                    chat = " ".join(value.split())[:80]
                    break

    record = {
        "id": session_id,
        "tool": tool,
        "cwd": cwd,
        "project": os.path.basename(cwd.rstrip("/")) or cwd,
        "state": state or previous.get("state") or "working",
        "title": title,
        "event": event,
        "updated": time.time(),
        "started": previous.get("started") or time.time(),
        "pid": previous.get("pid") or os.getppid(),
        "app": previous.get("app") or owning_app(os.getppid()),
        "chat": chat,
        # Handed to this run by another agent, rather than typed by a person.
        "origin": origin,
    }
    record.update({k: v or previous.get(k, "") for k, v in terminal_identity().items()})

    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(record, fh, ensure_ascii=False)
    os.replace(tmp, path)
    own_only(path, 0o600)
    return 0


if __name__ == "__main__":
    sys.exit(main())
