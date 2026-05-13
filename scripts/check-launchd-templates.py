#!/usr/bin/env python3
"""Reject committed LaunchAgent plists with local absolute user paths."""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    launchd = Path("launchd")
    failures: list[str] = []

    for plist in sorted(launchd.glob("*.plist")):
        failures.append(f"{plist}: commit .plist.template files, not rendered .plist")

    for template in sorted(launchd.glob("*.plist.template")):
        text = template.read_text(encoding="utf-8")
        if "/Users/" in text:
            failures.append(f"{template}: contains a hardcoded /Users path")
        if "__OS1_HOME__" not in text or "__OS1_PATH__" not in text:
            failures.append(f"{template}: missing __OS1_HOME__ or __OS1_PATH__")
        if (
            template.name
            in {
                "com.os1.app.plist.template",
                "com.os1.wuphf.plist.template",
            }
            and "__OS1_REPO_ROOT__" not in text
        ):
            failures.append(f"{template}: missing __OS1_REPO_ROOT__")

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
