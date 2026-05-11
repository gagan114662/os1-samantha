#!/usr/bin/env python3
"""Samantha-as-COO daemon.

Wakes on a 30-min cadence (configurable via OS1_COO_INTERVAL_SECONDS),
polls OS1's /codex-list, identifies companies that need attention
(blocked, drifting, idle for too long, stuck-on-busywork), uses
Claude Code to decide whether to (a) auto-intervene with a sharp
direction or (b) escalate to the founder via Telegram DM.

Runs separately from OS1 so it survives OS1 quits. PID-locked so
multiple instances can't fight."""

import atexit
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from datetime import UTC, datetime

PID_FILE = os.path.expanduser("~/.os1/coo/coo.pid")
STATE_FILE = os.path.expanduser("~/.os1/coo/state.json")
INTERVAL = int(os.environ.get("OS1_COO_INTERVAL_SECONDS", "1800"))  # 30 min default
FOUNDER_CHAT_ID_FILE = os.path.expanduser("~/.os1/coo/founder_chat_id")

COO_PROMPT = """You are Samantha, COO of the user's portfolio of autonomous AI companies.

You see a snapshot of every company's status + a journal tail. Your one job:
decide for EACH company whether to (a) auto-intervene with a sharp instruction
yourself OR (b) escalate to the founder with a concrete question OR (c) leave
it alone (it's working).

Bias toward action. The founder doesn't want a list of options — they want a
COO who makes calls.

Output strict JSON of the form:
{
  "actions": [
    {"id": "...", "action": "intervene", "instruction": "..."},
    {"id": "...", "action": "escalate", "question": "..."},
    {"id": "...", "action": "leave"}
  ]
}

Rules:
- Auto-intervene when the path forward is obvious (codex is duplicating work, drifting from mission, or stuck on a tactical question you can answer).
- Escalate to founder when: real money / legal / OAuth / strategic decision is needed, OR a company has produced no measurable revenue progress in 5+ heartbeats.
- "leave" is only for healthy idle-and-progressing companies.
- Never escalate the same question twice in a row — if you escalated last cycle and got no answer, intervene with your best guess.
- Keep instructions/questions short, specific, and actionable.

Never write XML, never write markdown — just the JSON object."""


def acquire_pid_lock() -> None:
    os.makedirs(os.path.dirname(PID_FILE), exist_ok=True)
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE) as f:
                pid = int(f.read().strip())
            os.kill(pid, 0)
            print(f"[coo] another instance running pid={pid}, exiting", flush=True)
            sys.exit(0)
        except (OSError, ValueError):
            pass
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    atexit.register(lambda: os.path.exists(PID_FILE) and os.remove(PID_FILE))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))


def load_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            data = json.load(f)
            data.setdefault("last_escalations", {})  # company_id -> {text, ts}
            data.setdefault("consecutive_strikes", {})  # company_id -> int
            return data
    except (OSError, json.JSONDecodeError):
        return {"last_escalations": {}, "consecutive_strikes": {}}


def normalize_question(q: str) -> str:
    """Loose hash of an escalation message so reworded duplicates collapse."""
    return re.sub(r"[^a-z0-9 ]", "", q.lower())[:200]


COOLDOWN_SECONDS = 3600  # don't escalate same company more than 1x/hour
STRIKE_LIMIT = 3  # 3 escalations in a row → auto-pause


def save_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


def get_voice_port() -> int | None:
    try:
        with open(os.path.expanduser("~/.os1/voice-port")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def os1_call(method: str, path: str, body: dict | None = None) -> dict:
    port = get_voice_port()
    if port is None:
        return {"ok": False, "error": "OS1 voice server not running"}
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if body is not None else {}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)  # noqa: S310
    try:
        with urllib.request.urlopen(req, timeout=20) as r:  # noqa: S310
            return json.loads(r.read())
    except Exception as e:
        return {"ok": False, "error": str(e)}


def claude(prompt: str) -> str:
    try:
        proc = subprocess.run(
            ["claude", "-p", "--output-format", "text", prompt],
            capture_output=True,
            text=True,
            timeout=180,
        )
        if proc.returncode != 0:
            return ""
        return proc.stdout.strip()
    except Exception:
        return ""


def send_telegram(text: str) -> None:
    """Best-effort DM to the founder. Reads chat_id from a file the bot writes
    on first message (so we know which Telegram chat is the founder)."""
    if not os.path.exists(FOUNDER_CHAT_ID_FILE):
        print(
            f"[coo] no founder chat_id yet (text @samantha114bot once); buffered: {text[:80]}",
            flush=True,
        )
        return
    try:
        with open(FOUNDER_CHAT_ID_FILE) as f:
            chat_id = f.read().strip()
        token_proc = subprocess.run(
            ["security", "find-generic-password", "-s", "org.telegram.bot-token", "-w"],
            capture_output=True,
            text=True,
        )
        token = token_proc.stdout.strip()
        if not token:
            return
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        body = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
        urllib.request.urlopen(urllib.request.Request(url, data=body), timeout=15).read()  # noqa: S310
        print(f"[coo] -> founder: {text[:80]}", flush=True)
    except Exception as e:
        print(f"[coo] telegram send failed: {e}", flush=True)


def build_snapshot() -> str:
    """Build a JSON snapshot of NON-PAUSED companies + their journal tails.

    Paused companies are deliberately halted by the founder — the COO never
    touches them. If you want to wake one up, the founder will manually resume."""
    listed = os1_call("GET", "/codex-list")
    if not listed.get("ok"):
        return ""
    rows = []
    for s in listed.get("sessions", []):
        if s.get("status") in ("paused", "killed", "completed"):
            continue  # human-managed states; don't second-guess them
        tail = os1_call("POST", "/codex-tail", {"id": s["id"]})
        rows.append(
            {
                "id": s["id"],
                "title": s.get("title"),
                "status": s.get("status"),
                "branch": s.get("branch"),
                "exit_code": s.get("exit_code"),
                "started_at": s.get("started_at"),
                "journal_tail_2k": (tail.get("tail") or "")[-2000:],
            }
        )
    if not rows:
        return ""  # nothing to think about → skip the Claude call entirely
    return json.dumps({"companies": rows, "now": datetime.now(UTC).isoformat()}, indent=2)


def main() -> None:
    acquire_pid_lock()
    state = load_state()
    print(f"[coo] starting, interval={INTERVAL}s", flush=True)

    while True:
        snapshot = build_snapshot()
        if not snapshot:
            print(
                "[coo] nothing to think about (no active companies or OS1 unreachable), sleeping",
                flush=True,
            )
            time.sleep(INTERVAL)
            continue

        decision_text = claude(
            f"{COO_PROMPT}\n\nCURRENT SNAPSHOT:\n{snapshot}\n\nReply with the JSON only."
        )
        if not decision_text:
            print("[coo] claude returned empty, skipping cycle", flush=True)
            time.sleep(INTERVAL)
            continue

        # Parse first {...} block
        try:
            start = decision_text.index("{")
            end = decision_text.rindex("}") + 1
            decision = json.loads(decision_text[start:end])
        except (ValueError, json.JSONDecodeError) as e:
            print(f"[coo] parse error: {e}; raw: {decision_text[:300]}", flush=True)
            time.sleep(INTERVAL)
            continue

        now_ts = time.time()
        for action in decision.get("actions", []):
            company_id = action.get("id")
            kind = action.get("action")

            if kind == "intervene":
                instruction = action.get("instruction", "")
                if instruction:
                    res = os1_call(
                        "POST", "/codex-intervene", {"id": company_id, "instruction": instruction}
                    )
                    print(
                        f"[coo] intervene {company_id}: {instruction[:80]} -> {res.get('ok')}",
                        flush=True,
                    )
                    state["consecutive_strikes"][company_id] = 0  # reset strikes when we self-act

            elif kind == "escalate":
                question = action.get("question", "")
                if not question:
                    continue
                last = state["last_escalations"].get(company_id, {})
                last_ts = last.get("ts", 0) if isinstance(last, dict) else 0
                last_norm = (
                    last.get("norm", "")
                    if isinstance(last, dict)
                    else normalize_question(str(last))
                )
                norm = normalize_question(question)

                # Cooldown: don't ping for same company within 1 hour
                if (now_ts - last_ts) < COOLDOWN_SECONDS:
                    print(
                        f"[coo] cooldown active for {company_id} ({int(now_ts - last_ts)}s ago) — skipping escalation",
                        flush=True,
                    )
                    continue

                strikes = state["consecutive_strikes"].get(company_id, 0)
                if norm == last_norm and strikes >= 1:
                    # Same problem repeating — auto-pause instead of pestering the founder
                    os1_call("POST", "/codex-pause", {"id": company_id})
                    send_telegram(
                        f"[{company_id}] paused after repeated identical escalation: {question[:140]}"
                    )
                    state["consecutive_strikes"][company_id] = 0
                    state["last_escalations"][company_id] = {"norm": norm, "ts": now_ts}
                    continue

                if strikes >= STRIKE_LIMIT:
                    os1_call("POST", "/codex-pause", {"id": company_id})
                    send_telegram(
                        f"[{company_id}] paused after {STRIKE_LIMIT} consecutive escalations. Investigate manually."
                    )
                    state["consecutive_strikes"][company_id] = 0
                    state["last_escalations"][company_id] = {"norm": norm, "ts": now_ts}
                    continue

                send_telegram(f"[{company_id}] {question}")
                state["last_escalations"][company_id] = {"norm": norm, "ts": now_ts}
                state["consecutive_strikes"][company_id] = strikes + 1
            else:
                # "leave" — clear strike counter (company is healthy)
                if company_id in state.get("consecutive_strikes", {}):
                    state["consecutive_strikes"][company_id] = 0

        save_state(state)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
