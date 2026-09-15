#!/usr/bin/env python3
"""Find local AI chat sessions by looking at what they left on disk.

The hooks in record.py only know about sessions started after they were
installed, and Codex only calls out at the end of a turn. Scanning the
transcript directories fills both gaps: any session whose log file was touched
recently is, for our purposes, a live session.

Writes the same shape as record.py into the same directory, but never
overwrites a hook-written record — the hook knows the real state, we are
guessing from a file's timestamp.
"""

import json
import datetime
import glob
import os
import re
import sqlite3
import subprocess
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

def _home(variable, fallback):
    """The home a tool was told to use, or the one it documents by default.

    `CLAUDE_CONFIG_DIR` and `CODEX_HOME` are the only knobs either tool
    promises, so they come first. Anyone who moved their home by hand was
    invisible before this, which is a far commoner arrangement than any
    particular cloning app.
    """
    told = os.environ.get(variable, "").strip()
    return os.path.expanduser(told or fallback)


CLAUDE_HOME = _home("CLAUDE_CONFIG_DIR", "~/.claude")
CLAUDE_ROOT = os.path.join(CLAUDE_HOME, "projects")
# The desktop app keeps a record per session with the summarised title it shows
# in its sidebar — the real title, not the first thing that was typed. The
# transcripts under CLAUDE_ROOT carry no title at all, so this is the only
# place to get one.
CLAUDE_SESSIONS = os.path.expanduser(
    "~/Library/Application Support/Claude/claude-code-sessions")
CODEX_HOME = _home("CODEX_HOME", "~/.codex")
CODEX_ROOT = os.path.join(CODEX_HOME, "sessions")
# Codex keeps its own index of every thread, with the user's messages stored
# apart from the preamble it injects — a far cleaner title source than the
# rollout files. Claude Code has no equivalent: its transcripts carry no
# summary entries at all, so there the first user message is the best we get.
CODEX_DB = os.path.join(CODEX_HOME, "thread_history_1.sqlite")
# Codex's own thread index: the title it shows in its sidebar, plus the working
# directory and the path to the rollout file. Far better than inferring any of
# it from the transcript.
CODEX_STATE_DB = os.path.join(CODEX_HOME, "state_5.sqlite")

# Every copy of the Codex app registers the codex:// scheme, so the OS hands a
# deep link to whichever one it picked rather than the one the thread lives in.
# Each copy keeps its own home directory, so the home a thread was found in is
# what says which app owns it — recorded per session and used to open it.
#
# Not every home has an app behind it: a home set up for the CLI alone holds
# real threads that no app can show. Those get no owner rather than a guess,
# since naming the wrong app is worse than letting the OS choose.
CODEX_HOME_GLOB = "~/.codex*"
STOCK_CODEX_BUNDLE = "com.openai.codex"
# Parallelly runs each cloned copy of the app against its own Codex home, and
# records the pairing here — the one authority on which clone owns which home.
PARALLELLY_PROFILES = os.path.expanduser(
    "~/Library/Application Support/Parallelly/Profiles")


def bundle_value(bundle, key):
    plist = os.path.join(bundle, "Contents", "Info.plist")
    try:
        out = subprocess.run(["plutil", "-extract", key, "raw", plist],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip() if out.returncode == 0 else ""


def installed_apps():
    """Every app bundle in the two places apps get installed."""
    for root in ("/Applications", os.path.expanduser("~/Applications")):
        try:
            names = os.listdir(root)
        except OSError:
            continue
        for name in names:
            if name.endswith(".app"):
                yield os.path.join(root, name)


def codex_home_owners():
    """Codex home -> the app bundle that runs against it.

    Clones are read from Parallelly's own profile directories, each of which
    points at the home its copy uses. The stock app is whatever is installed
    under the shipped bundle id, and owns the stock home.
    """
    owners = {}

    clones = {}
    for bundle in installed_apps():
        profile = bundle_value(bundle, "ParallellyProfileID")
        if profile:
            clones[profile.upper()] = bundle
        elif bundle_value(bundle, "CFBundleIdentifier") == STOCK_CODEX_BUNDLE:
            owners[os.path.realpath(CODEX_HOME)] = bundle

    try:
        profiles = os.listdir(PARALLELLY_PROFILES)
    except OSError:
        profiles = []
    for profile in profiles:
        bundle = clones.get(profile.upper())
        if not bundle:          # a profile whose copy is no longer installed
            continue
        home = os.path.join(PARALLELLY_PROFILES, profile, "CodexHome")
        if os.path.isdir(home):
            owners[os.path.realpath(home)] = bundle
    return owners


STOCK_CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"
# Every copy of the desktop app keeps its own session records, and every copy
# registers the claude:// scheme. Without knowing which copy filed a session,
# the link goes to whichever copy the OS happens to prefer — which is the clone.
CLAUDE_SESSION_DIR = "claude-code-sessions"


CLAUDE_CLI_DIR = "ClaudeConfig"


# Homes that told us about themselves. A hook runs inside the session, so it
# knows its own transcript path without anyone having to guess at directory
# layouts; scan.py just reads what they left. This is the part that needs no
# knowledge of any particular wrapper or cloning app.
KNOWN_ROOTS = os.path.join(STATE_DIR, "roots.json")


def remember_root(kind, root):
    """Note a transcript directory a hook actually ran in."""
    root = os.path.realpath(os.path.expanduser(root))
    if not os.path.isdir(root):
        return
    held = recall_roots()
    if root in held.get(kind, []):
        return
    held.setdefault(kind, []).append(root)
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


def recall_roots(kind=None):
    """What the hooks have registered, dropping anything since deleted."""
    try:
        with open(KNOWN_ROOTS) as fh:
            held = json.load(fh)
    except (IOError, OSError, ValueError):
        held = {}
    if not isinstance(held, dict):
        held = {}
    if kind is None:
        return held
    return [r for r in held.get(kind, []) if os.path.isdir(r)]


def claude_roots():
    """Every directory of Claude Code transcripts, newest-first per root.

    The rows come from transcripts, not from the app's own records, so a
    session whose transcript is not read never appears however well the app
    records are paired up. A Parallelly clone runs the CLI against its own
    config directory inside its profile, which is why the clone's work was
    missing even though the clone itself was being found.
    """
    roots = [CLAUDE_ROOT] + recall_roots("claude")
    try:
        profiles = os.listdir(PARALLELLY_PROFILES)
    except OSError:
        profiles = []
    for profile in profiles:
        root = os.path.join(PARALLELLY_PROFILES, profile, CLAUDE_CLI_DIR, "projects")
        if os.path.isdir(root):
            roots.append(root)
    seen, out = set(), []
    for root in roots:
        real = os.path.realpath(root)
        if real not in seen and os.path.isdir(real):
            seen.add(real)
            out.append(real)
    return out


def claude_homes():
    """Each directory of Claude session records, paired with its app.

    Same shape as `codex_homes`: a Parallelly clone keeps its records inside
    its own profile directory, and the profile id in the clone's Info.plist is
    what ties the two together. The stock app owns the plain Application
    Support directory. A copy nobody can name is still read — its sessions
    belong in the dock either way — it just gets no owner, and clicking it
    falls back to letting the OS choose.
    """
    homes = []
    seen = set()

    clones = {}
    stock = ""
    for bundle in installed_apps():
        profile = bundle_value(bundle, "ParallellyProfileID")
        if profile:
            clones[profile.upper()] = bundle
        elif bundle_value(bundle, "CFBundleIdentifier") == STOCK_CLAUDE_BUNDLE:
            stock = bundle

    def add(path, app):
        real = os.path.realpath(path)
        if os.path.isdir(real) and real not in seen:
            seen.add(real)
            homes.append((real, app))

    add(CLAUDE_SESSIONS, stock)

    try:
        profiles = os.listdir(PARALLELLY_PROFILES)
    except OSError:
        profiles = []
    for profile in profiles:
        add(os.path.join(PARALLELLY_PROFILES, profile, CLAUDE_SESSION_DIR),
            clones.get(profile.upper(), ""))

    # Copies that keep their records beside the stock directory rather than
    # inside a Parallelly profile. Nothing names their app, so they are read
    # for their titles alone.
    support = os.path.dirname(CLAUDE_SESSIONS)
    for name in sorted(glob.glob(os.path.join(os.path.dirname(support), "Claude-*"))):
        add(os.path.join(name, CLAUDE_SESSION_DIR), "")
    return homes


def codex_homes():
    """Each Codex home holding threads, paired with the app that owns it."""
    owners = codex_home_owners()
    homes = []
    for home in sorted(glob.glob(os.path.expanduser(CODEX_HOME_GLOB))):
        if not os.path.isfile(os.path.join(home, "state_5.sqlite")):
            continue            # not a Codex home, whatever else it is
        homes.append((home, owners.get(os.path.realpath(home), "")))
    return homes


# A transcript quiet for longer than this is not a session anyone is watching.
ACTIVE_WINDOW = 6 * 3600
# How far back records are kept, as opposed to how far back the dock shows by
# default. The dock can be asked to reach further than its usual few hours, and
# it can only reach as far as something was kept.
KEEP_WINDOW = 72 * 3600
# Touched this recently and it is probably mid-answer.
WORKING_WINDOW = 90
# A turn that has not written anything for this long is not still running.
# Both tools append to the transcript constantly while they work — tool
# results, token counts, per-item events — so silence means it stopped.
STALL_WINDOW = 10 * 60
# How long a record with nothing behind it is given before being cleared, so a
# hook that writes before the thread index catches up is not cut off.
ORPHAN_GRACE = 15 * 60
# How long a name is kept for a session nothing has seen.
TITLE_MEMORY = 30 * 86400


SYNTHETIC_PREFIXES = (
    "<task-notification>", "<system-reminder>", "<command-name>",
    "<command-message>", "<local-command-stdout>", "<user-prompt-submit-hook>",
)


def is_human_turn(entry):
    """Whether a user entry is a person typing, rather than the harness."""
    if entry.get("isMeta") or entry.get("isSidechain"):
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, list):
        # A turn made only of tool results is the harness handing work back.
        kinds = {part.get("type") for part in content if isinstance(part, dict)}
        if kinds and kinds <= {"tool_result"}:
            return False
        content = " ".join(part.get("text", "") for part in content
                           if isinstance(part, dict) and part.get("type") == "text")
    if not isinstance(content, str):
        return False
    return bool(content.strip()) and not content.lstrip().startswith(SYNTHETIC_PREFIXES)


# Only one of these puts a message on the queue. Everything else takes one
# off — a message can be dequeued to run, but it can also be removed by hand
# or cleared along with the rest, and counting only dequeue left the depth
# permanently above zero. A session in that state spun forever: the queue
# check runs before the transcript is read at all, so the end of the file
# never got a say.
QUEUE_ADDS = "enqueue"


def queued(entries):
    """Whether messages are still lined up behind the current turn."""
    depth = 0
    for entry in entries:
        if entry.get("type") != "queue-operation":
            continue
        if entry.get("operation") == QUEUE_ADDS:
            depth += 1
        else:
            # Anything else took a message off. Held at zero because the tail
            # is a window: its first entries can be the removals of messages
            # queued further back than we can see.
            depth = max(depth - 1, 0)
    return depth > 0


def state_from_tail(entries, tool):
    """Whose turn it is, read off the end of the transcript.

    A file timestamp only says how long ago something happened, never who is
    being waited on — which is why scanned sessions never showed as waiting.
    The last entry does say: an assistant message with no tool call means the
    answer landed and the session is now waiting on a person, however long ago
    that was.
    """
    if tool == "claude" and queued(entries):
        # Messages are lined up behind this turn, so whatever it says at the
        # end, nobody is being waited on: the session takes the next one by
        # itself. Showing it as your turn sent people to a session that was
        # about to carry on without them.
        return "working"

    for entry in reversed(entries):
        if tool == "claude":
            kind = entry.get("type")
            if kind == "assistant":
                # The model itself says whether it stopped to use a tool or
                # because it had finished, which beats guessing from the shape
                # of the content: it narrates part way through a turn and then
                # goes back to work, and that reads as a finished answer.
                reason = (entry.get("message") or {}).get("stop_reason")
                if reason == "tool_use":
                    return "working"
                if reason:
                    return "waiting"
            if kind == "user":
                # Not every user entry is a person typing. Tool results come
                # back as user turns, and so do the notices the harness injects
                # when a background task finishes or a command is run. Counting
                # those as a prompt left sessions reading "working" for days
                # after the person had walked away.
                if not is_human_turn(entry):
                    continue
                return "working"          # a prompt went in; a reply is coming
            if kind != "assistant":
                continue
            content = (entry.get("message") or {}).get("content")
            if isinstance(content, list):
                kinds = {part.get("type") for part in content
                         if isinstance(part, dict)}
                if "tool_use" in kinds:
                    return "working"      # mid-task, running something
            return "waiting"
        else:
            return codex_state(entries)
    return ""


CODEX_TOOL_CALLS = (
    "function_call", "custom_tool_call", "local_shell_call",
    "function_call_output", "custom_tool_call_output", "local_shell_call_output",
)


def codex_state(entries):
    """Whose turn it is in a Codex thread.

    Codex brackets each turn with task_started and task_complete, and that
    bracket is the only reliable answer. Everything inside it — tool calls,
    reasoning, token counts, even finished assistant messages — happens while
    the turn is still running: Codex narrates part way through and then goes
    back to work, so reading a message as the end of the turn made a busy
    session flip to waiting every time it said something.
    """
    for entry in reversed(entries):
        kind = (entry.get("payload") or {}).get("type")
        if kind == "task_complete":
            return "waiting"
        if kind == "task_started":
            return "working"

    # No bracket inside the window. Fall back to the finer signals, which are
    # wrong about narration mid-turn but better than nothing.
    for entry in reversed(entries):
        payload = entry.get("payload") or {}
        kind = payload.get("type")
        if kind in CODEX_TOOL_CALLS:
            return "working"
        if kind in ("message", "agent_message"):
            return "waiting" if payload.get("role") in ("assistant", None) \
                else "working"
    return ""


def newest_files(root, suffix, limit=400):
    """(path, mtime) for the most recently touched transcripts under root.

    Subagent transcripts are skipped. Claude Code files them under the session
    that spawned them, and they are not conversations anyone returns to — one
    piece of work fanning out to a dozen agents put a dozen rows in the dock,
    each labelled with the instructions it was handed.
    """
    found = []
    for base, dirs, names in os.walk(root):
        if os.path.basename(base) == "subagents":
            dirs[:] = []
            continue
        for name in names:
            if not name.endswith(suffix):
                continue
            path = os.path.join(base, name)
            try:
                found.append((path, os.path.getmtime(path)))
            except OSError:
                continue
    found.sort(key=lambda item: item[1], reverse=True)
    return found[:limit]


# Injected context and slash-command wrappers are not what the chat is about.
# Both tools wrap their preamble in XML-ish tags, so anything opening with one
# is machinery: a person almost never starts a message with "<".
NOISE_MARKERS = ("Caveat:", "This session is being continued")


def head_json_lines(path, count=120):
    """First few JSON objects of a transcript, for the opening exchange."""
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
                if len(out) >= count:
                    break
    except OSError:
        return []
    return out


def clean(text):
    """A single readable line, or "" if it is machinery rather than speech."""
    if not isinstance(text, str):
        return ""
    # Control characters survive from the terminal the line was typed into and
    # draw as a stray glyph at the head of the row.
    text = "".join(ch for ch in text if ch >= " " or ch in "\t\n\r")
    text = " ".join(text.split())
    if not text or text.startswith("<"):
        return ""
    if any(marker in text[:80] for marker in NOISE_MARKERS):
        return ""
    return text


def tail_json_lines(path, count=40):
    """Last few JSON objects of a .jsonl transcript, oldest first.

    The window has to be wide enough to reach whatever says whose turn it is.
    Codex writes a few hundred bookkeeping entries per turn — token counts,
    reasoning, per-item completions — so a window sized for Claude's denser
    transcript lands entirely inside one turn and finds nothing to go on.
    """
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            block = min(size, max(200_000, count * 4_000))
            fh.seek(size - block)
            raw = fh.read().decode("utf-8", "replace")
    except OSError:
        return []
    out = []
    for line in raw.splitlines()[-count:]:
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def claude_text(entry):
    """The words in one transcript entry, whoever said them."""
    message = entry.get("message") or {}
    content = message.get("content")
    if isinstance(content, str):
        return clean(content)
    if isinstance(content, list):
        parts = [part.get("text", "") for part in content
                 if isinstance(part, dict) and part.get("type") == "text"]
        return clean(" ".join(parts))
    return ""


TITLE_STORE = os.path.join(STATE_DIR, "titles.sqlite")


LEDGER = os.path.join(STATE_DIR, "ledger.json")
# One sample is never worth more than this. The scan stops while the machine
# sleeps or the app is quit, and without a cap the gap on waking would be
# booked as hours of somebody waiting.
SAMPLE_CAP = 120


def keep_ledger(db, sessions, now):
    """Add the time since the last look to whatever each session was doing.

    Sampling rather than watching for transitions: the scan already runs every
    few seconds, and a missed transition would cost a whole span while a missed
    sample costs only the interval.
    """
    if db is None:
        return
    try:
        db.execute("CREATE TABLE IF NOT EXISTS seen ("
                   "id TEXT PRIMARY KEY, state TEXT, at REAL)")
        db.execute("CREATE TABLE IF NOT EXISTS ledger ("
                   "day TEXT, state TEXT, seconds REAL, PRIMARY KEY (day, state))")
        held = {row[0]: (row[1], row[2])
                for row in db.execute("SELECT id, state, at FROM seen")}
        day = datetime.datetime.fromtimestamp(now).strftime("%Y-%m-%d")
        for key, state in sessions.items():
            was = held.get(key)
            if was and was[0] in ("waiting", "working"):
                span = min(now - was[1], SAMPLE_CAP)
                if span > 0:
                    db.execute(
                        "INSERT INTO ledger (day, state, seconds) VALUES (?, ?, ?) "
                        "ON CONFLICT(day, state) DO UPDATE SET "
                        "seconds = seconds + excluded.seconds", (day, was[0], span))
            db.execute("INSERT INTO seen (id, state, at) VALUES (?, ?, ?) "
                       "ON CONFLICT(id) DO UPDATE SET state = excluded.state, "
                       "at = excluded.at", (key, state, now))
        gone = set(held) - set(sessions)
        for key in gone:
            db.execute("DELETE FROM seen WHERE id = ?", (key,))
        db.commit()
    except sqlite3.Error:
        return
    publish_ledger(db, day, now)


def publish_ledger(db, day, now):
    """A small file the dock reads, so it needs no database of its own."""
    try:
        rows = dict(db.execute(
            "SELECT state, seconds FROM ledger WHERE day = ?", (day,)).fetchall())
    except sqlite3.Error:
        return
    longest = ("", 0.0)
    for name in os.listdir(STATE_DIR):
        if not name.endswith(".json") or not name.startswith(("claude-", "codex-")):
            continue
        try:
            with open(os.path.join(STATE_DIR, name)) as fh:
                record = json.load(fh)
        except (IOError, OSError, ValueError):
            continue
        if record.get("state") != "waiting":
            continue
        idle = now - float(record.get("updated", 0))
        if idle > longest[1]:
            longest = (record.get("chat") or record.get("project") or "", idle)
    summary = {
        "day": day,
        "waited_on_me": rows.get("waiting", 0.0),
        "waited_on_them": rows.get("working", 0.0),
        "longest_chat": longest[0],
        "longest_seconds": longest[1],
    }
    tmp = LEDGER + ".tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(summary, fh, ensure_ascii=False)
        os.replace(tmp, LEDGER)
    except OSError:
        pass


def title_store():
    """A title, once learnt, is kept.

    Titles come from records the desktop app rewrites constantly, and each is
    a few hundred kilobytes. Reading one mid-rewrite fails, and every session
    in that file loses its name for that pass — the row falls back to its
    folder and the dock appears to forget what the conversation was. Holding
    them here means a name can only ever be replaced by a better one.
    """
    try:
        db = sqlite3.connect(TITLE_STORE, timeout=2)
        db.execute("CREATE TABLE IF NOT EXISTS titles ("
                   "id TEXT PRIMARY KEY, title TEXT, seen REAL)")
        return db
    except sqlite3.Error:
        return None


def recall_titles(db):
    if db is None:
        return {}
    try:
        return {row[0]: row[1] for row in db.execute("SELECT id, title FROM titles")}
    except sqlite3.Error:
        return {}


def remember_title(db, session_id, title, when):
    if db is None or not title:
        return
    try:
        db.execute("INSERT INTO titles (id, title, seen) VALUES (?, ?, ?) "
                   "ON CONFLICT(id) DO UPDATE SET title = excluded.title, "
                   "seen = excluded.seen", (session_id, title, when))
    except sqlite3.Error:
        pass


def forget_titles(db, before):
    """Drop names for sessions nothing has seen in a long while."""
    if db is None:
        return
    try:
        db.execute("DELETE FROM titles WHERE seen < ?", (before,))
    except sqlite3.Error:
        pass


def claude_titles():
    """{cli session id: (title, cwd, last activity, app id, owning app)}."""
    out = {}
    for home, app in claude_homes():
        _claude_titles_in(home, app, out)
    return out


def _claude_titles_in(home, app, out):
    for base, _, names in os.walk(home):
        for name in names:
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(base, name)) as fh:
                    record = json.load(fh)
            except (IOError, OSError, ValueError):
                continue
            if record.get("isArchived"):
                continue
            title = clean(record.get("title") or "")
            if not title:
                continue
            when = float(record.get("lastActivityAt") or 0)
            if when > 1e11:            # milliseconds
                when /= 1000.0
            # The id the app files this conversation under. For most
            # sessions it matches the CLI id, but one that has been used
            # through Remote Control is filed under a different one, and
            # addressing it by the CLI id makes the app miss and record the
            # conversation a second time.
            own = str(record.get("sessionId") or "")
            if own.startswith("local_"):
                own = own[len("local_"):]
            entry = (title, record.get("cwd") or "", when, own, app)
            # One conversation can have more than one record: the app keeps a
            # separate one for a session that was bridged to a remote, and
            # both carry the same cliSessionId. Whichever is read first would
            # otherwise win, and the order files come back in is arbitrary, so
            # the one that saw activity most recently is kept.
            for key in (record.get("cliSessionId"), record.get("sessionId")):
                if not key:
                    continue
                held = out.get(key)
                if held is None or when >= held[2]:
                    out[key] = entry
            for key in record.get("bridgeSessionIds") or []:
                held = out.get(key)
                if held is None or when >= held[2]:
                    out[key] = entry


def first_human_line(path, limit=6000):
    """The first thing a person actually typed, however deep it sits.

    A session continued after a compaction opens with the handover preamble
    and then a long run of tool results, so the opening exchange is not near
    the top of the file at all. Reading only the first entries left those rows
    with no title and falling back to the name of their folder.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for count, line in enumerate(fh):
                if count >= limit:
                    break
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if entry.get("type") != "user" or not is_human_turn(entry):
                    continue
                text = claude_text(entry)
                if text:
                    return text
    except OSError:
        return ""
    return ""


def last_spoken(entries):
    """When the last entry was written, by its own timestamp.

    A file's modification time only says when it was last written to, and
    Claude Code appends bookkeeping to transcripts long after the conversation
    ended. Sorting on that floated months-old sessions to the top of the dock
    as though they had just moved.
    """
    for entry in reversed(entries):
        stamp = entry.get("timestamp")
        if not isinstance(stamp, str):
            continue
        text = stamp.replace("Z", "+0000")
        for shape in ("%Y-%m-%dT%H:%M:%S.%f%z", "%Y-%m-%dT%H:%M:%S%z"):
            try:
                return datetime.datetime.strptime(text, shape).timestamp()
            except ValueError:
                continue
    return 0


def running(pid, born, slack=2.0):
    """Whether the process that was driving a session is still the one there.

    A pid on its own is not an answer: macOS hands the numbers out again, so
    a long-finished session can point at something entirely unrelated that
    happens to be alive now. The birth time settles it — a recycled pid comes
    with a process younger than the record that named it.
    """
    if not pid:
        return None                  # nothing was ever recorded; no opinion
    try:
        os.kill(int(pid), 0)
    except ProcessLookupError:
        return False
    except (OSError, ValueError):
        return None                  # no permission to ask, so no opinion
    if not born:
        return True                  # alive, and nothing to check it against
    now_born = process_born(pid)
    if not now_born:
        return True
    return abs(now_born - float(born)) <= slack


def process_born(pid):
    """When the process holding this pid began, or 0 if it cannot be read."""
    try:
        out = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                             capture_output=True, text=True, timeout=5).stdout
        text = " ".join(out.split())
        if not text:
            return 0.0
        return time.mktime(time.strptime(text, "%a %b %d %H:%M:%S %Y"))
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0.0


def settle(state, touched, now):
    """A turn nothing has written to in a long while has stopped.

    Quitting the app part way through a turn leaves the transcript ending on a
    tool call with nothing to close it, and reading that literally left the
    session "working" for as long as the record survived.
    """
    if state == "working" and now - touched > STALL_WINDOW:
        return "waiting"
    return state


def claude_sessions():
    titles = claude_titles()
    for root in claude_roots():
        yield from _claude_sessions_in(root, titles)


def _claude_sessions_in(root, titles):
    for path, mtime in newest_files(root, ".jsonl"):
        if time.time() - mtime > KEEP_WINDOW:
            break
        session_id = os.path.basename(path)[:-len(".jsonl")]
        cwd = ""
        title = ""
        # What the conversation is about: the first thing the user actually
        # typed, which beats any summary the transcript does not carry.
        titled = titles.get(session_id)
        chat = titled[0] if titled else ""
        filed = titled[3] if titled else ""
        # Which copy of the desktop app filed this conversation. Every copy
        # answers claude://, so without this the link lands wherever the OS
        # feels like sending it, and a session started in the original opens
        # in a clone that has never seen it.
        app = titled[4] if titled else ""
        tail = tail_json_lines(path, count=200)
        state = state_from_tail(tail, "claude")
        if not chat:
            # No record from the app: fall back to what the user opened with.
            chat = first_human_line(path)
        for entry in tail:
            cwd = entry.get("cwd") or cwd
            message = entry.get("message") or {}
            if entry.get("type") == "user" and isinstance(message.get("content"), str):
                title = message["content"]
            elif entry.get("type") == "assistant":
                content = message.get("content")
                if isinstance(content, list):
                    for part in content:
                        if isinstance(part, dict) and part.get("type") == "text":
                            title = part.get("text", "") or title
        if not cwd and titled:
            cwd = titled[1]
        if not cwd:
            # ~/.claude/projects/-Users-me-thing/<id>.jsonl
            folder = os.path.basename(os.path.dirname(path))
            cwd = folder.replace("-", "/", 1).replace("-", "/")
        yield (session_id, "claude", cwd, title, chat,
               settle(state, mtime, time.time()),
               last_spoken(tail) or mtime, app, filed, "")


def codex_query(path, sql):
    """Read-only query, so a running Codex is never blocked."""
    if not os.path.exists(path):
        return []
    try:
        uri = "file:%s?mode=ro" % path
        with sqlite3.connect(uri, uri=True, timeout=2) as db:
            return db.execute(sql).fetchall()
    except sqlite3.Error:
        return []


# Codex hands work to sub-agents by opening a thread of its own for each one,
# so a single question of yours can leave half a dozen nameless rows behind.
# The index says which those are: `thread_source` is "subagent" for a spawned
# run and "guardian_review" for the review pass, and for a spawn the `source`
# column carries the parent thread's id. Delegated work, in other words, in
# exactly the sense the dock already has a switch for.
SPAWNED = ("subagent", "guardian_review")


def spawned_by(thread_source, source):
    """"agent" for a thread Codex opened for itself, "" for one you opened."""
    if (thread_source or "").strip() in SPAWNED:
        return "agent"
    if (source or "").lstrip().startswith('{"subagent"'):
        return "agent"
    return ""


def codex_sessions():
    """Straight from Codex's thread index, which knows the title it displays.

    Read once per installed copy of the app: each keeps its own home, and a
    thread only exists in the one it was started in.
    """
    now = time.time()
    for home, app in codex_homes():
        # `name` is the summarised title Codex shows once it has one; `title`
        # is only ever the first message. Prefer the summary, fall back to it.
        rows = codex_query(os.path.join(home, "state_5.sqlite"), """
            SELECT id, COALESCE(NULLIF(name, ''), title), cwd, updated_at, rollout_path,
                   thread_source, source
              FROM threads
             WHERE archived = 0
             ORDER BY updated_at DESC
             LIMIT 60
        """)
        for (thread_id, title, cwd, updated_at, rollout_path,
             thread_source, source) in rows:
            when = float(updated_at or 0)
            if when > 1e11:          # some rows are milliseconds
                when /= 1000.0
            if now - when > KEEP_WINDOW:
                break

            chat = clean(title or "")
            state = ""
            last = ""
            if rollout_path and os.path.exists(rollout_path):
                tail = tail_json_lines(rollout_path, count=400)
                state = settle(state_from_tail(tail, "codex"),
                               os.path.getmtime(rollout_path), now)
                for entry in tail:
                    payload = entry.get("payload") or entry
                    text = payload.get("text") or payload.get("message") or ""
                    if isinstance(text, str) and text.strip():
                        last = text
            yield (thread_id, "codex", cwd or "", last, chat, state, when, app, "",
                   spawned_by(thread_source, source))


def main():
    os.makedirs(STATE_DIR, exist_ok=True)
    own_only(STATE_DIR, 0o700)
    now = time.time()
    written = 0
    seen = set()
    booked = {}
    store = title_store()
    remembered = recall_titles(store)

    for (session_id, tool, cwd, title, chat, state, mtime, app,
         filed, origin) in list(claude_sessions()) + list(codex_sessions()):
        path = os.path.join(STATE_DIR, "%s-%s.json" % (tool, session_id))
        seen.add(path)
        booked[path] = state
        chat = " ".join((chat or "").split())[:80]
        if chat:
            remember_title(store, session_id, chat, now)
        else:
            chat = remembered.get(session_id, "")
        previous = ""
        if os.path.exists(path):
            try:
                with open(path) as fh:
                    existing = json.load(fh)
                previous = existing.get("state") or ""
                # A hook wrote this; it knows the state better than a file
                # timestamp does. Still hand it the chat title and the owning
                # app, neither of which the hook is in a position to know.
                if existing.get("source") != "scan":
                    changed = False
                    if chat and existing.get("chat") != chat:
                        existing["chat"] = " ".join(chat.split())[:80]
                        changed = True
                    if app and existing.get("app") != app:
                        existing["app"] = app
                        changed = True
                    if filed and existing.get("filed") != filed:
                        existing["filed"] = filed
                        changed = True
                    if origin and existing.get("origin") != origin:
                        existing["origin"] = origin
                        changed = True
                    # How far the transcript is allowed to overrule a hook
                    # depends on what that tool's hooks actually report.
                    #
                    # Codex rings once, at the end of a turn, and says nothing
                    # when one starts. A session that went back to work would
                    # carry "waiting" until it stopped again, so there the
                    # transcript wins wherever it has moved since.
                    #
                    # Claude fires on every tool call as well as at the end,
                    # so its record is already right to the second and far
                    # better than anything the transcript can be read for: it
                    # narrates part way through a turn and then carries on
                    # working, which reads as finished. All the transcript is
                    # trusted for there is unsticking a run that ended without
                    # a closing event — a crash, a quit — and left "working"
                    # behind for good.
                    settled = existing.get("state") == "working" and (
                        now - float(existing.get("updated", 0)) > WORKING_WINDOW)

                    # The process that was doing the work is gone, so the work
                    # is too, whatever the last event said. A hook only fires
                    # while the session is alive, so a crash or a quit leaves
                    # "working" behind with nothing to take it back — which is
                    # what left rows spinning until the stall window ran out
                    # ten minutes later. This costs one signal-zero.
                    if existing.get("state") == "working" and running(
                            existing.get("pid"), existing.get("born")) is False:
                        existing["state"] = "waiting"
                        changed = True
                    if state and tool == "codex" and mtime > float(existing.get("updated", 0)):
                        if state != existing.get("state"):
                            existing["state"] = state
                        existing["updated"] = mtime
                        changed = True
                    elif state and settled and state != existing.get("state"):
                        existing["state"] = state
                        changed = True
                    if changed:
                        tmp = path + ".tmp"
                        with open(tmp, "w") as fh:
                            json.dump(existing, fh, ensure_ascii=False)
                        os.replace(tmp, path)
                        own_only(path, 0o600)
                    continue
            except (IOError, OSError, ValueError):
                pass

        record = {
            "id": session_id,
            "tool": tool,
            "cwd": cwd,
            "project": os.path.basename(cwd.rstrip("/")) or cwd or "(알 수 없음)",
            # A session waiting on a person stays waiting, however stale the
            # file is. When the transcript says nothing either way, hold what
            # was there before: guessing from the file clock made a session
            # flip to working every time a bookkeeping line was appended and
            # fall back to idle ninety seconds later, so rows blinked in and
            # out while nothing about the session had changed.
            # A held state carries forward only while it is still plausible:
            # "working" with nothing to back it up outlives the work itself.
            "state": state or settle(previous, mtime, now)
                     or ("working" if now - mtime < WORKING_WINDOW else "idle"),
            "title": " ".join((title or "").split())[:120],
            "chat": chat,
            "event": "scan",
            "source": "scan",
            "updated": mtime,
            "started": mtime,
            "pid": 0,
            "app": app,
            # The id the desktop app files this conversation under, which is
            # what a link has to name to land on it rather than make another.
            "filed": filed,
            # Empty unless the thread was opened by the agent rather than by
            # you; the dock keeps those behind the delegated-work switch.
            "origin": origin,
            "term_program": "",
            "term_session": "",
            "window_title": "",
        }
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(record, fh, ensure_ascii=False)
        os.replace(tmp, path)
        own_only(path, 0o600)
        written += 1

    # Drop anything that has gone quiet for good.
    for name in os.listdir(STATE_DIR):
        # Only the session records. The ledger lives in this directory too, and
        # sweeping it up as a session with no timestamp had it deleted on every
        # pass and written again straight after.
        if not name.endswith(".json") or not name.startswith(("claude-", "codex-")):
            continue
        path = os.path.join(STATE_DIR, name)
        try:
            with open(path) as fh:
                record = json.load(fh)
            # Subagents used to get rows of their own; clear out any left over
            # from before they were skipped.
            if str(record.get("id", "")).startswith("agent-"):
                os.remove(path)
                continue
            # Nothing on disk backs this any more: no transcript, and no row
            # in any thread index. The session was deleted, and the row was
            # sitting in the dock until it aged out, pointing at a
            # conversation that had stopped existing. A hook can legitimately
            # get there before the index does, so a record still in motion is
            # left alone.
            if path not in seen and now - float(record.get("updated", 0)) > ORPHAN_GRACE:
                os.remove(path)
                continue
            if now - float(record.get("updated", 0)) > KEEP_WINDOW:
                os.remove(path)
        except (IOError, OSError, ValueError):
            continue

    if store is not None:
        keep_ledger(store, {
            os.path.basename(path)[:-len(".json")]: state
            for path, state in booked.items()
        }, now)
        forget_titles(store, now - TITLE_MEMORY)
        try:
            store.commit()
            store.close()
        except sqlite3.Error:
            pass

    print("스캔: %d건 기록" % written)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
