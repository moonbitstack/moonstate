#!/usr/bin/env python3
"""Draw the social card: `docs/og.png`, 1200x630.

The card is a rendering of a real state of the line graph — three supersteps,
four checkpoints, `n = 12` — with the same geometry as the dial on the home page.
It is written here rather than screenshotted from the site because a viewport
crop of the home page cuts the demo panel in half, and a share card that looks
like an accident is worse than none.

Usage:
    python scripts/gen_og.py            # writes docs/_og.html
    python scripts/gen_og.py --shoot    # writes the html, then asks Chrome for the png

`--shoot` looks for Chrome in the usual Windows and macOS places, or takes
`CHROME=/path/to/chrome`.
"""

from __future__ import annotations

import argparse
import math
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMP = ROOT / "docs" / "_og.html"
OUT = ROOT / "docs" / "og.png"

CENTRE = 260.0
RADIUS = 200.0
LIMIT = 25
PHASE = 3
CHECKPOINTS = [0, 1, 2, 3]

PAPER = "#f1f0e7"
INK = "#12201b"
MUTED = "#5d6a63"
RULE = "#c8cec1"
ACCENT = "#14604e"
JADE = "#2c8a7d"


def at(index: int) -> float:
    return math.radians(-90 + index * 360 / LIMIT)


def point(index: int, radius: float) -> tuple[float, float]:
    angle = at(index)
    return CENTRE + radius * math.cos(angle), CENTRE + radius * math.sin(angle)


def ring() -> str:
    ticks = []
    for i in range(LIMIT):
        x1, y1 = point(i, RADIUS - 6)
        x2, y2 = point(i, RADIUS + (11 if i % 5 == 0 else 7))
        width = 2.8 if i == PHASE else (1.5 if i < PHASE else 1)
        colour = JADE if i == PHASE else (ACCENT if i < PHASE else "rgb(18 32 27 / 0.3)")
        ticks.append(
            f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{colour}" stroke-width="{width}"/>'
        )

    numerals = []
    for i in range(5, LIMIT, 5):
        x, y = point(i, RADIUS + 30)
        numerals.append(
            f'<text x="{x:.1f}" y="{y + 4:.1f}" text-anchor="middle" '
            f'font-family="ui-monospace, Consolas, monospace" font-size="12" '
            f'fill="{MUTED}">{i}</text>'
        )

    x1, y1 = point(0, RADIUS)
    x2, y2 = point(PHASE, RADIUS)
    arc = (
        f'<path d="M{x1:.1f} {y1:.1f} A{RADIUS} {RADIUS} 0 0 1 {x2:.1f} {y2:.1f}" '
        f'fill="none" stroke="{ACCENT}" stroke-width="3" stroke-linecap="round"/>'
    )

    notches = []
    for step in CHECKPOINTS:
        x, y = point(step, RADIUS)
        notches.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{PAPER}" '
            f'stroke="{ACCENT}" stroke-width="1.4"/>'
        )

    cx1, cy1 = point(PHASE, RADIUS + 14)
    cx2, cy2 = point(PHASE, RADIUS + 23)
    cap = (
        f'<line x1="{cx1:.1f}" y1="{cy1:.1f}" x2="{cx2:.1f}" y2="{cy2:.1f}" '
        f'stroke="{JADE}" stroke-width="2" stroke-linecap="round"/>'
    )

    return f"""<svg viewBox="0 0 520 520" width="520" height="520" role="img">
  <circle cx="260" cy="260" r="200" fill="none" stroke="{RULE}" stroke-width="1"/>
  <circle cx="260" cy="260" r="150" fill="none" stroke="{RULE}" stroke-width="0.75" stroke-dasharray="1 8"/>
  {''.join(ticks)}
  {arc}
  {''.join(notches)}
  {cap}
  {''.join(numerals)}
</svg>"""


def page() -> str:
    return f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8">
<style>
  html, body {{ margin: 0; background: {PAPER}; color: {INK}; }}
  body {{ width: 1200px; height: 630px; overflow: hidden; font-family: Georgia, "Times New Roman", serif; }}
  .card {{ display: grid; grid-template-columns: 560px 1fr; gap: 48px; padding: 56px 64px 48px 56px; align-items: center; }}
  .mark {{ display: flex; align-items: center; gap: 12px; font-size: 27px; letter-spacing: 0.01em; }}
  .mark i {{ width: 17px; height: 17px; border: 1.5px solid {ACCENT}; border-radius: 50%;
            background: radial-gradient(circle at 50% 50%, {PAPER} 0 26%, transparent 27%),
                        linear-gradient(90deg, {JADE} 0 50%, transparent 50%); }}
  h1 {{ font-weight: 400; font-size: 48px; line-height: 1.1; letter-spacing: -0.015em; margin: 24px 0 22px; max-width: 17ch; }}
  p {{ font-family: ui-sans-serif, "Segoe UI", Helvetica, Arial, sans-serif; font-size: 19px; line-height: 1.55;
       color: {MUTED}; margin: 0 0 28px; max-width: 26ch; }}
  .url {{ font-family: ui-monospace, Consolas, monospace; font-size: 13px; letter-spacing: 0.04em; color: {ACCENT}; }}
  .rule {{ height: 1px; background: {RULE}; margin: 26px 0 0; width: 120px; }}
  .reading {{ position: absolute; inset: 0; display: grid; place-content: center;
              justify-items: center; text-align: center; }}
  .count {{ font-size: 92px; line-height: 1; letter-spacing: -0.03em; }}
  .unit {{ font-family: ui-monospace, Consolas, monospace; font-size: 13px; letter-spacing: 0.22em;
           text-transform: uppercase; color: {MUTED}; margin-top: 10px; }}
  .verdict {{ font-family: ui-monospace, Consolas, monospace; font-size: 14px; color: {ACCENT}; margin-top: 22px; }}
  .state {{ font-family: ui-monospace, Consolas, monospace; font-size: 16px; margin-top: 14px; }}
  .budget {{ font-family: ui-monospace, Consolas, monospace; font-size: 11px; letter-spacing: 0.16em;
             text-transform: uppercase; color: {MUTED}; margin-top: 18px; opacity: 0.8; }}
  .ring {{ position: relative; width: 520px; height: 520px; }}
</style>
</head>
<body>
  <div class="card">
    <div class="ring">
      {ring()}
      <div class="reading">
        <div class="count">3</div>
        <div class="unit">supersteps</div>
        <div class="verdict">the graph ended · 4 checkpoints</div>
        <div class="state">n = 12 · log = [stamp]</div>
        <div class="budget">limit 25</div>
      </div>
    </div>
    <div>
      <div class="mark"><i></i>moonstate</div>
      <h1>Durable state graphs, and nothing else.</h1>
      <p>Every superstep is a checkpoint. Kill the process mid-run and it carries on where it stopped.</p>
      <div class="rule"></div>
      <div class="url">moonbitstack.github.io/moonstate</div>
    </div>
  </div>
</body>
</html>
"""


def find_chrome() -> str | None:
    env = os.environ.get("CHROME")
    if env:
        return env
    candidates = [
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
    ]
    for path in candidates:
        if pathlib.Path(path).exists():
            return path
    return shutil.which("chrome") or shutil.which("chromium")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shoot", action="store_true", help="also render the png with Chrome")
    args = parser.parse_args()

    TEMP.write_text(page(), encoding="utf-8", newline="\n")
    print(f"wrote {TEMP.relative_to(ROOT)}")

    if not args.shoot:
        return 0

    chrome = find_chrome()
    if not chrome:
        print("no Chrome found; set CHROME=/path/to/chrome", file=sys.stderr)
        return 1

    subprocess.run(
        [
            chrome,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--force-device-scale-factor=1",
            "--window-size=1200,630",
            "--virtual-time-budget=3000",
            f"--screenshot={OUT}",
            TEMP.as_uri(),
        ],
        check=True,
        capture_output=True,
    )
    print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
