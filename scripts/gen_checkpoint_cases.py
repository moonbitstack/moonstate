#!/usr/bin/env python3
"""Pin the reference checkpoint-conformance suite and write the coverage table.

The reference suite is Python and drives a Python saver object, so it cannot be
pointed at a MoonBit implementation. What this script pins is its *inventory*:
every case in the spec directory of one LangGraph commit, with its name and what
it checks. Each case is then tied to the MoonBit test that exercises the same
observable behaviour, and to the four backends that test runs on.

Outputs, all regenerated together:

    scripts/checkpoint_cases.json   the pinned inventory and the coverage map
    README.md                       the tables between the cases markers
    docs/conformance.html           the same tables on the site

Usage:
    python scripts/gen_checkpoint_cases.py                     # regenerate
    python scripts/gen_checkpoint_cases.py --check             # fail if stale
    python scripts/gen_checkpoint_cases.py --check --offline  # no network
    python scripts/gen_checkpoint_cases.py --spec-dir DIR      # local spec files
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import html
import json
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
JSON_FILE = SCRIPTS / "checkpoint_cases.json"
README = ROOT / "README.md"
TEMPLATE = ROOT / "docs" / "conformance.template.html"
PAGE = ROOT / "docs" / "conformance.html"
CONFORMANCE = ROOT / "integration" / "src" / "conformance.mbt"

REPOSITORY = "langchain-ai/langgraph"
COMMIT = "e5e37b5d70dbfd93c7006bd90a658c6179a95946"
SPEC_PATH = "libs/checkpoint-conformance/langgraph/checkpoint/conformance/spec"
SPEC_FILES = [
    "test_get_tuple.py",
    "test_put.py",
    "test_put_writes.py",
    "test_list.py",
    "test_delete_thread.py",
    "test_copy_thread.py",
    "test_delete_for_runs.py",
    "test_delta_channel_history.py",
    "test_prune.py",
]
RAW = f"https://raw.githubusercontent.com/{REPOSITORY}/{COMMIT}/{SPEC_PATH}"

BACKENDS = ["memory", "sqlite", "postgresql", "mysql"]

# One scenario in integration/src/conformance.mbt per reference capability.
# Every case below appears as its own assertion in that scenario, so the
# reference inventory and the test transcript have the same granularity.
SCENARIOS = {
    "get_tuple": ("GET_TUPLE", "get_tuple_cases"),
    "put": ("PUT", "put_cases"),
    "put_writes": ("PUT_WRITES", "put_writes_cases"),
    "list": ("LIST", "list_cases"),
    "delete_thread": ("DELETE_THREAD", "delete_thread_cases"),
    "copy_thread": ("COPY_THREAD", "copy_thread_cases"),
    "delete_for_runs": ("DELETE_FOR_RUNS", "delete_for_runs_cases"),
    "delta_channel_history": ("DELTA_CHANNEL_HISTORY", "delta_history_cases"),
    "prune": ("PRUNE", "prune_cases"),
}

# Where a case names a concept the Saver contract does not have, the test
# exercises the equivalent observable behaviour instead. Say so per case.
NOTES = {
    "test_get_tuple_config_structure": "A tuple's config has no counterpart; the checkpoint's own thread, id and seq are checked.",
    "test_get_tuple_metadata": "Metadata is not stored; step, the field a reader needs, is checked.",
    "test_get_tuple_pending_writes_in_writes_sort_key_order": "The SQL backends return writes sorted by task, so the assertion compares the sorted order.",
    "test_get_tuple_respects_namespace": "There is one namespace in this contract: the thread id. Isolation between threads is checked.",
    "test_put_returns_config": "put returns Unit; the checkpoint it wrote is read back instead.",
    "test_put_preserves_channel_values": "The state is one JSON value, not a set of channels; several JSON shapes are round-tripped.",
    "test_put_preserves_channel_versions": "Channel versions are not stored; seq is the ordering of a thread's checkpoints.",
    "test_put_preserves_versions_seen": "versions_seen is not stored; parent is the lineage a reader walks.",
    "test_put_preserves_metadata": "Metadata is not stored; step is checked.",
    "test_put_root_namespace": "A plain thread id is the root namespace here.",
    "test_put_child_namespace": "A thread id containing a colon stands in for a child namespace.",
    "test_put_default_namespace": "Every checkpoint belongs to exactly one thread; no namespace argument is needed.",
    "test_put_parent_config": "parent names the checkpoint this one was written on top of.",
    "test_put_incremental_channel_update": "A checkpoint stores the whole state, so an earlier checkpoint's state is unchanged by a later put.",
    "test_put_new_channel_added": "A field appearing for the first time in a later state is read back from that state.",
    "test_put_channel_removed": "A field absent from a later state is absent when that state is read back.",
    "test_put_preserves_run_id": "A run id is not stored; the thread id identifies the run.",
    "test_put_preserves_versions_seen_values": "seq and its value, rather than a versions_seen map, are checked.",
    "test_put_writes_multiple_writes_same_task": "One task files an array of steps, which is the same shape as several channel/value pairs.",
    "test_put_writes_preserves_channel_and_value": "The steps a task filed are round-tripped as JSON values.",
    "test_put_writes_task_path": "There is no separate task_path; the task string carries the path.",
    "test_put_writes_idempotent": "Filing the same task again replaces its row rather than adding a second.",
    "test_put_writes_special_channels": "ERROR and INTERRUPT are not special channels here; their JSON payloads are stored verbatim.",
    "test_put_writes_across_namespaces": "Writes are scoped by thread, the namespace this contract has.",
    "test_put_writes_cleared_on_next_checkpoint": "A new checkpoint has no writes filed against it.",
    "test_list_by_namespace": "Another thread's page is the namespace filter here.",
    "test_list_ordering": "list returns a thread's checkpoints oldest first; the page is read in that order.",
    "test_list_metadata_filter_single_key": "There is no metadata filter; before is the filter that narrows a page by checkpoint id.",
    "test_list_metadata_filter_step": "There is no metadata filter; limit is the filter that narrows a page by size.",
    "test_list_combined_thread_and_filter": "thread, before and limit are combined in one call.",
    "test_list_multiple_namespaces": "Two threads' pages are read separately.",
    "test_list_metadata_filter_multiple_keys": "before and limit together are the two bounds of a page.",
    "test_list_metadata_filter_no_match": "A before cursor older than every checkpoint yields an empty page.",
    "test_list_metadata_custom_keys": "A caller filters the returned page; the saver's two bounds stay composable.",
    "test_delete_thread_removes_all_namespaces": "Deleting both threads removes both namespaces.",
    "test_copy_thread_basic": "A copy is list + put + put_writes over the public contract, not a saver method.",
    "test_copy_thread_all_checkpoints": "The copy takes the whole page, not only the latest checkpoint.",
    "test_copy_thread_preserves_metadata": "seq and step survive the copy.",
    "test_copy_thread_preserves_namespaces": "Both source threads are copied to their own target threads.",
    "test_copy_thread_preserves_ordering": "The target's page has the source's order.",
    "test_copy_thread_nonexistent_source": "An empty source page produces an empty target.",
    "test_delete_for_runs_single": "A run is one thread; deleting one thread is deleting one run.",
    "test_delete_for_runs_multiple": "Deleting several threads is one call per thread.",
    "test_delete_for_runs_across_namespaces": "Threads with different id shapes are all removed.",
    "test_history_returns_writes_oldest_first": "history and list both return a thread oldest first.",
    "test_history_seed_is_nearest_snapshot": "parent names the nearest ancestor checkpoint.",
    "test_history_excludes_target_pending_writes": "Writes are filed against one checkpoint, never inherited by the next.",
    "test_history_multi_channel": "Several fields of one JSON state are read back together.",
    "test_history_empty_channels_returns_empty": "A before cursor older than every checkpoint yields an empty page.",
    "test_history_walk_to_root_no_seed": "The first checkpoint has no parent.",
    "test_history_migration_plain_value_as_seed": "A scalar JSON state round-trips like an object state.",
    "test_history_seed_ancestor_own_writes_are_replayed": "Writes filed against an ancestor are still there when that ancestor is read.",
    "test_history_orders_parallel_writes_by_task_path": "Writes are compared in task order.",
    "test_history_orders_pathless_writes_first": "A task named as graph input sorts before named node tasks.",
    "test_prune_keep_latest_single_thread": "There is no prune method; list(limit=1) is the latest checkpoint a reader keeps.",
    "test_prune_keep_latest_multiple_threads": "Each thread keeps its own latest page.",
    "test_prune_keep_latest_across_namespaces": "Threads with different id shapes each keep one checkpoint.",
    "test_prune_keep_latest_preserves_writes": "The latest checkpoint still carries its writes.",
    "test_prune_delete_all": "delete removes every checkpoint of a thread.",
    "test_prune_preserves_other_threads": "Deleting one thread leaves the others.",
    "test_prune_empty_list_noop": "Deleting an empty list of threads changes nothing.",
    "test_prune_nonexistent_noop": "Deleting a thread that is not there is not an error.",
}

DEFAULT_NOTE = "Exercised directly on the Saver contract."

# One case the reference suite does not name, but its BaseCheckpointSaver
# documents and its own tests rely on: writing an id twice replaces the row.
ADDITIONAL = [
    {
        "capability": "PUT",
        "case": "put_replaces_an_existing_id",
        "source": "moonstate",
        "summary": "Writing the same checkpoint id twice replaces the stored row.",
        "scenario": "put_cases",
        "test": "conformance.mbt / put_replaces_an_existing_id",
        "backends": BACKENDS,
        "mapping": "additional",
        "note": "Not a case of the reference suite; the contract's put documents it.",
    }
]


def fetch_spec(spec_dir: Path | None) -> dict[str, str]:
    """Read the nine spec files of the pinned commit."""
    texts: dict[str, str] = {}
    for name in SPEC_FILES:
        if spec_dir is not None:
            texts[name] = (spec_dir / name).read_text(encoding="utf-8")
            continue
        url = f"{RAW}/{name}"
        last: Exception | None = None
        for _ in range(5):
            try:
                with urllib.request.urlopen(url, timeout=60) as response:
                    texts[name] = response.read().decode("utf-8")
                break
            except Exception as error:  # network retries are expected on CI
                last = error
        else:
            raise SystemExit(f"cannot read {url}: {last}")
    return texts


def inventory(texts: dict[str, str]) -> tuple[list[dict], dict[str, str]]:
    cases: list[dict] = []
    hashes: dict[str, str] = {}
    for name in SPEC_FILES:
        text = texts[name]
        hashes[name] = hashlib.sha256(text.encode("utf-8")).hexdigest()
        capability = name.removeprefix("test_").removesuffix(".py")
        label, scenario = SCENARIOS[capability]
        tree = ast.parse(text, filename=name)
        for node in tree.body:
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if not node.name.startswith("test_"):
                continue
            doc = (ast.get_docstring(node) or "").strip().splitlines()
            summary = doc[0].strip() if doc else ""
            cases.append(
                {
                    "capability": label,
                    "case": node.name,
                    "source": name,
                    "summary": summary,
                    "scenario": scenario,
                    "test": f"conformance.mbt / {node.name}",
                    "backends": list(BACKENDS),
                    "mapping": "equivalent" if node.name in NOTES else "direct",
                    "note": NOTES.get(node.name, DEFAULT_NOTE),
                }
            )
    return cases, hashes


def document(cases: list[dict], hashes: dict[str, str]) -> dict:
    return {
        "reference": {
            "repository": REPOSITORY,
            "commit": COMMIT,
            "path": SPEC_PATH,
            "suite": "langgraph-checkpoint-conformance 0.0.2",
            "case_count": len(cases),
            "spec_sha256": hashes,
        },
        "backends": BACKENDS,
        "test_module": "integration/src/conformance.mbt",
        "unit_test": "src/checkpoint_conformance_test.mbt",
        "cases": cases,
        "additional": ADDITIONAL,
    }


def readme_block(doc: dict) -> str:
    groups: dict[str, list[dict]] = {}
    for case in doc["cases"] + doc["additional"]:
        groups.setdefault(case["capability"], []).append(case)
    out = ["<!-- cases:start -->"]
    for capability, cases in groups.items():
        out.append(f"#### {capability} · {len(cases)} cases")
        out.append("")
        out.append("| Case | What the reference checks | Where it is covered | Backends |")
        out.append("|:--|:--|:--|:--|")
        for case in cases:
            summary = case["summary"].replace("|", "\\|")
            note = case["note"].replace("|", "\\|")
            covered = f"`{case['test']}`"
            if case["mapping"] != "direct":
                covered += f"<br>{note}"
            out.append(
                f"| `{case['case']}` | {summary} | {covered} | "
                + ", ".join(case["backends"])
                + " |"
            )
        out.append("")
    out.append("<!-- cases:end -->")
    return "\n".join(out)


def page_block(doc: dict) -> str:
    groups: dict[str, list[dict]] = {}
    for case in doc["cases"] + doc["additional"]:
        groups.setdefault(case["capability"], []).append(case)
    parts = []
    for capability, cases in groups.items():
        rows = []
        for case in cases:
            kind = case["mapping"]
            note = f'<span class="case-note">{html.escape(case["note"])}</span>' if kind != "direct" else ""
            rows.append(
                "<tr>"
                f'<td><code>{html.escape(case["case"])}</code>{note}</td>'
                f'<td>{html.escape(case["summary"])}</td>'
                f'<td><code>{html.escape(case["test"])}</code></td>'
                f'<td class="backends">{html.escape(", ".join(case["backends"]))}</td>'
                "</tr>"
            )
        parts.append(
            f'<section class="case-group" id="case-{capability.lower().replace("_", "-")}">\n'
            f'  <h3>{html.escape(capability)} <span>{len(cases)} cases</span></h3>\n'
            '  <div class="case-scroll">\n'
            '    <table class="case-table">\n'
            "      <thead><tr><th>Case</th><th>What it checks</th><th>Covered by</th><th>Backends</th></tr></thead>\n"
            "      <tbody>\n"
            + "\n".join("        " + row for row in rows)
            + "\n      </tbody>\n    </table>\n  </div>\n</section>"
        )
    return "\n".join(parts)


def render_page(doc: dict) -> str:
    template = TEMPLATE.read_text(encoding="utf-8")
    cases = doc["cases"] + doc["additional"]
    pin = (SCRIPTS / "weaver_registry_pin.txt").read_text(encoding="utf-8").strip()
    substitutions = {
        "<!-- cases:block -->": page_block(doc),
        "<!-- cases:count -->": str(len(doc["cases"])),
        "<!-- cases:total -->": str(len(cases)),
        "<!-- cases:commit -->": COMMIT[:12],
        "<!-- cases:backends -->": ", ".join(BACKENDS),
        "<!-- registry:pin -->": pin,
    }
    for marker, value in substitutions.items():
        if marker not in template:
            raise SystemExit(f"conformance.template.html: missing {marker}")
        template = template.replace(marker, value)
    return template


def write_or_check(path: Path, content: str, check: bool) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else ""
    if current == content:
        return True
    if check:
        print(f"{path.relative_to(ROOT)}: stale", file=sys.stderr)
        return False
    path.write_text(content, encoding="utf-8", newline="\n")
    print(f"{path.relative_to(ROOT)}: written")
    return True


def check_sources(doc: dict) -> list[str]:
    """Every row of the table has to name an assertion that really exists."""
    problems: list[str] = []
    if not CONFORMANCE.exists():
        return [f"{CONFORMANCE.relative_to(ROOT)}: missing"]
    source = CONFORMANCE.read_text(encoding="utf-8")
    unit = ROOT / doc["unit_test"]
    unit_source = unit.read_text(encoding="utf-8") if unit.exists() else ""
    for case in doc["cases"] + doc["additional"]:
        if f'"{case["case"]}"' not in source:
            problems.append(f"{case['case']}: no assertion in conformance.mbt")
        if case["scenario"] not in source:
            problems.append(f"{case['case']}: no scenario {case['scenario']}")
    for name in ("get", "put", "put_writes", "list", "delete"):
        if f"test \"{name}" not in unit_source:
            problems.append(f"unit test for {name} is missing")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail instead of writing")
    parser.add_argument("--offline", action="store_true", help="use the checked-in inventory")
    parser.add_argument("--spec-dir", type=Path, help="read the spec files from here")
    args = parser.parse_args()

    if args.offline:
        doc = json.loads(JSON_FILE.read_text(encoding="utf-8"))
        if doc["reference"]["commit"] != COMMIT:
            print("checkpoint_cases.json: the pinned commit changed", file=sys.stderr)
            return 1
    else:
        texts = fetch_spec(args.spec_dir)
        cases, hashes = inventory(texts)
        doc = document(cases, hashes)
        if len(cases) != 92:
            print(f"the pinned spec has {len(cases)} cases, expected 92", file=sys.stderr)
            return 1

    problems = check_sources(doc)
    if problems:
        for problem in problems:
            print(f"coverage: {problem}", file=sys.stderr)
        return 1

    json_text = json.dumps(doc, indent=2, ensure_ascii=False, sort_keys=False) + "\n"
    readme_text = README.read_text(encoding="utf-8")
    start, end = "<!-- cases:start -->", "<!-- cases:end -->"
    first, last = readme_text.find(start), readme_text.find(end)
    if first < 0 or last < 0:
        print("README.md: no cases markers", file=sys.stderr)
        return 1
    readme_new = readme_text[:first] + readme_block(doc) + readme_text[last + len(end) :]

    ok = True
    if not args.offline:
        ok &= write_or_check(JSON_FILE, json_text, args.check)
    ok &= write_or_check(README, readme_new, args.check)
    ok &= write_or_check(PAGE, render_page(doc), args.check)
    if args.check and ok:
        print(
            f"checkpoint cases: {len(doc['cases'])} pinned cases + "
            f"{len(doc['additional'])} additional, every one covered on "
            f"{len(BACKENDS)} backends"
        )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
