#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHD_DIR="$ROOT_DIR/launchd"
TARGET_DIR="${OS1_LAUNCH_AGENT_TARGET_DIR:-$HOME/Library/LaunchAgents}"
OS1_PATH="${OS1_PATH:-/opt/homebrew/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
DRY_RUN="${OS1_LAUNCH_AGENTS_DRY_RUN:-0}"
FORCE_RELOAD=0
GUI_DOMAIN="gui/$(id -u)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reload)
            FORCE_RELOAD=1
            ;;
        -h|--help)
            echo "Usage: scripts/install-launch-agents.sh [--reload]"
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 2
            ;;
    esac
    shift
done

mkdir -p "$TARGET_DIR" "$HOME/.os1"

render_template() {
    local template="$1"
    local destination="$2"

    OS1_REPO_ROOT="$ROOT_DIR" OS1_HOME="$HOME" OS1_PATH="$OS1_PATH" python3 - "$template" "$destination" <<'PY'
import html
import os
import pathlib
import sys

template = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])

text = template.read_text(encoding="utf-8")
text = text.replace("__OS1_REPO_ROOT__", html.escape(os.environ["OS1_REPO_ROOT"], quote=False))
text = text.replace("__OS1_HOME__", html.escape(os.environ["OS1_HOME"], quote=False))
text = text.replace("__OS1_PATH__", html.escape(os.environ["OS1_PATH"], quote=False))
if "__OS1_" in text:
    unresolved = sorted({part.split("__", 1)[0] for part in text.split("__OS1_")[1:]})
    raise SystemExit(f"unresolved LaunchAgent template placeholder(s): {', '.join(unresolved)}")
destination.write_text(text, encoding="utf-8")
PY
}

bootout_agent() {
    local label="$1"
    local plist="$2"

    launchctl bootout "$GUI_DOMAIN/$label" >/dev/null 2>&1 || true
    launchctl bootout "$GUI_DOMAIN" "$plist" >/dev/null 2>&1 || true
    launchctl unload "$plist" >/dev/null 2>&1 || true
}

bootstrap_agent() {
    local plist="$1"

    if ! launchctl bootstrap "$GUI_DOMAIN" "$plist" >/dev/null 2>&1; then
        launchctl load -w "$plist"
    fi
    launchctl enable "$GUI_DOMAIN/$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")" >/dev/null 2>&1 || true
}

agent_loaded() {
    local label="$1"
    launchctl print "$GUI_DOMAIN/$label" >/dev/null 2>&1
}

kill_stale_wuphf_listener() {
    local pids
    pids="$(lsof -tiTCP:7891 -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$pids" ]] || return 0

    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        local command
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command" == *"wuphf"* && "$command" != *"wuphf-stripe-webhook-proxy.py"* ]]; then
            echo "Killing stale raw WUPHF listener on :7891 (pid $pid)"
            kill "$pid" >/dev/null 2>&1 || true
        fi
    done <<<"$pids"
}

changed=0
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/os1-launch-agents.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

shopt -s nullglob
templates=("$LAUNCHD_DIR"/com.os1.*.plist.template)
if (( ${#templates[@]} == 0 )); then
    echo "error: no LaunchAgent templates found in $LAUNCHD_DIR" >&2
    exit 1
fi

for template in "${templates[@]}"; do
    plist_name="$(basename "${template%.template}")"
    label="${plist_name%.plist}"
    rendered="$tmp_dir/$plist_name"
    target="$TARGET_DIR/$plist_name"

    render_template "$template" "$rendered"
    plutil -lint "$rendered" >/dev/null
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "Validated LaunchAgent template: $plist_name"
        continue
    fi

    if [[ -f "$target" ]] && cmp -s "$rendered" "$target"; then
        echo "LaunchAgent current: $target"
        if (( FORCE_RELOAD == 1 )); then
            bootout_agent "$label" "$target"
            bootstrap_agent "$target"
        elif ! agent_loaded "$label"; then
            bootstrap_agent "$target"
        fi
    else
        bootout_agent "$label" "$target"
        install -m 0644 "$rendered" "$target"
        changed=1
        echo "Installed LaunchAgent: $target"
        bootstrap_agent "$target"
    fi

    if [[ "$label" == "com.os1.wuphf" ]]; then
        kill_stale_wuphf_listener
    fi
done

if (( changed == 0 )); then
    echo "LaunchAgents already up to date."
else
    echo "LaunchAgents installed and reloaded."
fi
