#!/usr/bin/env python3
"""Fill the numbers on the home page from the repository.

A number on a page is a promise about the code, so none of them is typed by
hand: the version comes from `moon.mod`, the phase count from the constant the
engine uses, and the differential counts from the vectors the Python reference
generated. `--check` fails when the page disagrees with the sources, which is
what CI runs.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PAGE = ROOT / "docs" / "index.html"
START = "<!-- numbers:start -->"
END = "<!-- numbers:end -->"


def read(pattern: str, path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    match = re.search(pattern, text, re.M)
    if not match:
        raise SystemExit(f"{path.name}: no match for {pattern!r}")
    return match.group(1)


def figures() -> list[tuple[str, str]]:
    version = read(r'^version\s*=\s*"([^"]+)"', ROOT / "moon.mod")
    limit = read(r"default_limit\s*:\s*Int32\s*=\s*(\d+)", ROOT / "src" / "graph.mbt")

    vectors = json.loads((ROOT / "scripts" / "vectors.json").read_text(encoding="utf-8"))
    graphs = len(vectors)
    checkpoints = sum(len(vector.get("snapshots") or ()) for vector in vectors)

    return [
        (version, "the version"),
        (limit, "supersteps a run may take"),
        (str(graphs), "graphs compared with LangGraph"),
        (str(checkpoints), "checkpoints compared, one by one"),
    ]


def block(figures_: list[tuple[str, str]]) -> str:
    cells = "\n".join(
        f'            <div><b>{value}</b><span>{label}</span></div>'
        for value, label in figures_
    )
    return (
        f"{START}\n"
        '          <div class="numbers">\n'
        f"{cells}\n"
        "          </div>\n"
        f"          {END}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail instead of writing")
    args = parser.parse_args()

    page = PAGE.read_text(encoding="utf-8")
    start = page.find(START)
    end = page.find(END)
    if start < 0 or end < 0:
        raise SystemExit(f"{PAGE.name}: the numbers markers are missing")

    updated = page[:start] + block(figures()) + page[end + len(END) :]

    if args.check:
        if updated != page:
            print("docs/index.html: the numbers disagree with the sources", file=sys.stderr)
            return 1
        print("docs/index.html: the numbers match the sources")
        return 0

    PAGE.write_text(updated, encoding="utf-8", newline="\n")
    print(f"docs/index.html: wrote {len(figures())} figures")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
