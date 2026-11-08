#!/usr/bin/env python3
"""Write docs/guide.html from docs/guide.template.html and the README's blocks.

The guide shows the same code the README shows, and neither is copied by hand:
the template names a block by its position in the README and this script pastes
it in. `check_snippets.py` then compiles the result, so a block that stops
compiling fails CI twice over.
"""

from __future__ import annotations

import argparse
import html
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs" / "guide.template.html"
PAGE = ROOT / "docs" / "guide.html"
README = ROOT / "README.md"

BLOCK = re.compile(r"^```moonbit\n(.*?)^```", re.S | re.M)
PLACEHOLDER = re.compile(r"<!--\s*code:(\d+)\s*-->")


def blocks() -> list[str]:
    found = BLOCK.findall(README.read_text(encoding="utf-8"))
    if not found:
        raise SystemExit("README.md: no moonbit blocks found")
    return found


def render(template: str, code: list[str]) -> str:
    def paste(match: re.Match[str]) -> str:
        index = int(match.group(1))
        if index >= len(code):
            raise SystemExit(f"guide.template.html: no block {index} in the README")
        body = code[index].strip("\n")
        return f'<pre class="sig"><code>{html.escape(body, quote=False)}</code></pre>'

    return PLACEHOLDER.sub(paste, template)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail instead of writing")
    args = parser.parse_args()

    page = render(TEMPLATE.read_text(encoding="utf-8"), blocks())

    if args.check:
        current = PAGE.read_text(encoding="utf-8") if PAGE.exists() else ""
        if current != page:
            print("docs/guide.html: stale — rerun scripts/gen_guide.py", file=sys.stderr)
            return 1
        print("docs/guide.html: up to date")
        return 0

    PAGE.write_text(page, encoding="utf-8", newline="\n")
    print("docs/guide.html: written")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
