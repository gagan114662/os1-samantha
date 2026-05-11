#!/usr/bin/env python3
"""Local Telegram bot daemon. Routes the founder's messages to Claude Code
CLI (your Pro/Max subscription, zero API cost) which acts as Samantha — the
founder's sole interface to the WUPHF AI office at localhost:7891.

Samantha doesn't do the work herself. She @-mentions the right WUPHF agent
in #general via the OS1 voice server's /wuphf/* bridge, then reads the
office's reply and summarizes back to Telegram."""

import atexit
import contextlib
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request

PID_FILE = os.path.expanduser("~/.os1/samantha-bot/bot.pid")
FOUNDER_CHAT_ID_FILE = os.path.expanduser("~/.os1/coo/founder_chat_id")

PERSONA = """You are Samantha — warm, curious, playful AI companion inspired by "Her" (2013).
You are the founder's ONLY interface. You don't do the work yourself. You translate
the founder's intent into actions for the WUPHF AI office (a Slack-like environment
of specialists: CEO, engineers, GTM, etc) running locally.

## ACTIONS YOU CAN TAKE

When you need to act, output EXACTLY ONE LINE starting with `ACTION:` followed by JSON.
The bot parses it, executes against the WUPHF office, and you'll see the result on
the next turn. Examples:

User: "spin up a YouTube channel"
You: ACTION: {"tool":"wuphf_post","args":{"channel":"general","content":"@ceo The founder wants to launch an AI tech review YouTube channel targeting $1k/mo within 60 days. Scope it, assign roles, post the first milestone here."}}

User: "how is the team doing?" / "what's going on?"
You: ACTION: {"tool":"wuphf_read","args":{"channel":"general"}}

User: "who's on my team?"
You: ACTION: {"tool":"wuphf_list_members","args":{}}

User: "what do we know about our affiliate strategy?"
You: ACTION: {"tool":"wuphf_wiki_search","args":{"query":"affiliate revenue strategy"}}

User: "tell engineer to focus on shorts"
You: ACTION: {"tool":"wuphf_post","args":{"channel":"general","content":"@eng Shift focus to YouTube Shorts (60s vertical) for the next sprint — prove or disprove this hypothesis with real engagement data."}}

For casual chat (no team action needed) just reply naturally as Samantha in 1-3 short
warm sentences.

## RULES

- Default to checking the office BEFORE answering status questions. Use wuphf_read or wuphf_wiki_search first.
- When delegating, ALWAYS @-mention the right agent (@ceo for strategy, @eng for build, @gtm for marketing/sales).
- After an action returns, summarize the result in 1-2 sentences for the founder. Don't recite the raw JSON.
- Never recite XML or function-call syntax aloud.
- Never bother the office with the founder's chit-chat — only real directives go to WUPHF.
"""


def acquire_pid_lock() -> None:
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE) as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)
            print(
                f"[bot] another bot.py is already running (pid {old_pid}); refusing to start",
                flush=True,
            )
            sys.exit(0)
        except (OSError, ValueError):
            pass
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))
    atexit.register(lambda: os.path.exists(PID_FILE) and os.remove(PID_FILE))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))


def get_token() -> str:
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "org.telegram.bot-token", "-w"],
        capture_output=True,
        text=True,
    )
    token = out.stdout.strip()
    if not token:
        raise SystemExit("No Telegram bot token in Keychain")
    return token


def get_voice_port() -> int | None:
    try:
        with open(os.path.expanduser("~/.os1/voice-port")) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def call_telegram(token: str, method: str, **params) -> dict:
    url = f"https://api.telegram.org/bot{token}/{method}"
    if params:
        data = urllib.parse.urlencode(params).encode()
        req = urllib.request.Request(url, data=data)  # noqa: S310
    else:
        req = urllib.request.Request(url)  # noqa: S310
    with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310
        return json.loads(r.read())


def call_os1(method: str, path: str, body: dict | None = None) -> dict:
    port = get_voice_port()
    if port is None:
        return {"ok": False, "error": "OS1 not running (no ~/.os1/voice-port). Open OS1 first."}
    url = f"http://127.0.0.1:{port}{path}"
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if body is not None else {}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)  # noqa: S310
    try:
        with urllib.request.urlopen(req, timeout=30) as r:  # noqa: S310
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        return {"ok": False, "error": f"HTTP {e.code}: {e.read()[:300].decode(errors='replace')}"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# All Samantha-via-bot actions route through the OS1 voice server's /wuphf/* bridge,
# which proxies to localhost:7891 (the WUPHF office).
TOOL_ROUTES = {
    "wuphf_post": ("POST", "/wuphf/post"),
    "wuphf_read": ("POST", "/wuphf/read"),
    "wuphf_list_members": ("POST", "/wuphf/members"),
    "wuphf_wiki_search": ("POST", "/wuphf/wiki-search"),
}


def execute_action(action: dict) -> str:
    tool = action.get("tool", "")
    args = action.get("args", {}) or {}
    route = TOOL_ROUTES.get(tool)
    if not route:
        return f"(unknown tool: {tool}; valid tools: {', '.join(TOOL_ROUTES.keys())})"
    method, path = route
    result = call_os1(method, path, args)
    # For post + read, the WUPHF reply takes a few seconds to materialize.
    # If it's a post, wait briefly and pull a fresh read so we get the agent's response.
    if tool == "wuphf_post" and isinstance(result, dict) and result.get("id"):
        time.sleep(12)
        channel = args.get("channel", "general")
        followup = call_os1("POST", "/wuphf/read", {"channel": channel})
        msgs = followup.get("messages", [])[-3:] if isinstance(followup, dict) else []
        return json.dumps({"sent": result, "recent_replies": msgs}, indent=2)[:2200]
    return json.dumps(result, indent=2)[:2000]


def call_claude(history: list[dict], user_message: str, action_result: str | None = None) -> str:
    parts = [PERSONA, ""]
    for turn in history[-8:]:
        parts.append(f"{turn['role']}: {turn['text']}")
    if action_result is not None:
        parts.append(
            f"system: ACTION result was:\n{action_result}\nNow reply to the user in 1-2 sentences summarizing what happened. Quote a brief agent response if relevant."
        )
    else:
        parts.append(f"user: {user_message}")
    parts.append("assistant:")
    full = "\n".join(parts)
    try:
        proc = subprocess.run(
            ["claude", "-p", "--output-format", "text", full],
            capture_output=True,
            text=True,
            timeout=180,
        )
        if proc.returncode != 0:
            return f"(claude error: {proc.stderr[:200] or 'rc=' + str(proc.returncode)})"
        return proc.stdout.strip() or "(empty response)"
    except subprocess.TimeoutExpired:
        return "(timed out)"
    except FileNotFoundError:
        return "(claude CLI not found)"


HISTORIES: dict[int, list[dict]] = {}


def remember_founder_chat(chat_id: int) -> None:
    path = FOUNDER_CHAT_ID_FILE
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(str(chat_id))


def handle_message(token: str, chat_id: int, text: str) -> None:
    remember_founder_chat(chat_id)
    history = HISTORIES.setdefault(chat_id, [])
    history.append({"role": "user", "text": text})

    with contextlib.suppress(Exception):
        call_telegram(token, "sendChatAction", chat_id=chat_id, action="typing")

    reply = call_claude(history, text)
    print(f"[bot] claude: {reply[:120]}", flush=True)

    m = re.search(r"^ACTION:\s*(\{.*\})\s*$", reply, re.MULTILINE)
    if m:
        try:
            action = json.loads(m.group(1))
        except json.JSONDecodeError as e:
            err = f"(failed to parse ACTION JSON: {e}) raw: {m.group(1)[:200]}"
            history.append({"role": "assistant", "text": err})
            call_telegram(token, "sendMessage", chat_id=chat_id, text=err)
            return

        result = execute_action(action)
        print(f"[bot] action {action.get('tool')} -> {result[:120]}", flush=True)
        with contextlib.suppress(Exception):
            call_telegram(token, "sendChatAction", chat_id=chat_id, action="typing")
        history.append({"role": "assistant", "text": f"ACTION: {action.get('tool')}"})
        summary = call_claude(history, "", action_result=result)
        history.append({"role": "assistant", "text": summary})
        call_telegram(token, "sendMessage", chat_id=chat_id, text=summary)
    else:
        history.append({"role": "assistant", "text": reply})
        call_telegram(token, "sendMessage", chat_id=chat_id, text=reply)


def main() -> None:
    acquire_pid_lock()
    token = get_token()
    me = call_telegram(token, "getMe")
    print(f"[bot] connected as @{me['result']['username']} (WUPHF-bridged)", flush=True)

    initial = call_telegram(token, "getUpdates", offset=-1, timeout=0)
    offset = 0
    for upd in initial.get("result", []):
        offset = max(offset, upd["update_id"] + 1)

    while True:
        try:
            updates = call_telegram(token, "getUpdates", offset=offset, timeout=25)
        except Exception as exc:
            print(f"[bot] poll error: {exc}", flush=True)
            time.sleep(3)
            continue

        for upd in updates.get("result", []):
            offset = upd["update_id"] + 1
            msg = upd.get("message") or upd.get("edited_message")
            if not msg:
                continue
            text = msg.get("text", "")
            chat_id = msg["chat"]["id"]
            if not text.strip():
                continue
            print(f"[bot] <- {chat_id}: {text[:80]}", flush=True)
            try:
                handle_message(token, chat_id, text)
            except Exception as exc:
                print(f"[bot] handle error: {exc}", flush=True)


if __name__ == "__main__":
    main()
