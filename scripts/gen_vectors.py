#!/usr/bin/env python3
"""Generate the differential vectors for moonstate from LangGraph 1.2.

Each vector is a graph described as data, run once here and once by the MoonBit
test suite. Both sides record the same thing — the state after every superstep
and the writes that produced it — so a difference in merging, routing, Send,
interrupts, retries or time travel shows up as a diff rather than as a hunch.

Only the public LangGraph API is used, so the vectors are worth exactly what the
reference implementation is worth.

Usage:
    python scripts/gen_vectors.py            # rewrite vectors.json and the test data
    python scripts/gen_vectors.py --check    # fail if either file would change
"""

from __future__ import annotations

import json
import operator
import sys
from pathlib import Path
from typing import Annotated, Any, TypedDict

from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Command, RetryPolicy, Send, interrupt

ROOT = Path(__file__).resolve().parent
VECTORS = ROOT / "vectors.json"
DATA = ROOT.parent / "src" / "vectors_data_test.mbt"


class State(TypedDict):
    n: int
    log: Annotated[list[str], operator.add]


class Draft(TypedDict):
    value: int


class Transient(Exception):
    """A failure worth another try. LangGraph retries anything its default
    predicate does not explicitly reject, and it rejects RuntimeError."""


def child_graph(delta: int) -> Any:
    graph = StateGraph(Draft)
    graph.add_node("grow", lambda draft: {"value": draft["value"] + delta})
    graph.add_edge(START, "grow")
    graph.add_edge("grow", END)
    return graph.compile()


def node_of(op: dict[str, Any], attempts: dict[str, int], name: str):
    """The function one node of the spec runs."""
    kind = op.get("kind", "pass")
    if kind == "bump":
        delta = op.get("delta", 1)
        label = op["label"]

        def bump(state: State) -> dict[str, Any]:
            return {"n": state["n"] + delta, "log": [label]}

        return bump
    if kind == "note":
        label = op["label"]

        def note(_state: State) -> dict[str, Any]:
            return {"log": [label]}

        return note
    if kind == "label_n":
        prefix = op["prefix"]

        def label_n(state: State) -> dict[str, Any]:
            return {"log": [f"{prefix}{state['n']}"]}

        return label_n
    if kind == "goto":
        target = op["to"]
        label = op.get("label")

        def goto(_state: State) -> Any:
            if label is None:
                return Command(goto=target)
            return Command(goto=target, update={"log": [label]})

        return goto
    if kind == "send":
        count = op["count"]

        def fan(_state: State) -> Any:
            return Command(
                goto=[
                    Send("worker", {"n": index, "log": [f"job{index}"]})
                    for index in range(count)
                ]
            )

        return fan
    if kind == "gate":
        label = op.get("label", "gate")

        def gate(_state: State) -> dict[str, Any]:
            answer = interrupt({"ask": "number"})
            return {"n": answer, "log": [label]}

        return gate
    if kind == "fail_once":
        label = op["label"]

        def fail_once(state: State) -> dict[str, Any]:
            attempts[name] = attempts.get(name, 0) + 1
            if attempts[name] == 1:
                raise Transient("the first attempt fails")
            return {"n": state["n"], "log": [label]}

        return fail_once
    if kind == "sub":
        delta = op["delta"]
        label = op.get("label", "sub")

        def sub(state: State) -> dict[str, Any]:
            out = child_graph(delta).invoke({"value": state["n"]})
            return {"n": out["value"], "log": [label]}

        return sub
    if kind == "pass":

        def nothing(_state: State) -> dict[str, Any]:
            return {}

        return nothing
    raise SystemExit(f"unknown op {kind}")


def build(spec: dict[str, Any], attempts: dict[str, int]) -> Any:
    graph = StateGraph(State)
    routes = {branch["from"]: branch for branch in spec.get("branches", [])}
    retries = spec.get("retry", {})
    for node in spec["nodes"]:
        name = node["id"]
        op = node.get("op", {"kind": "pass"})
        policy = retries.get(name)
        if policy is not None:
            graph.add_node(
                name,
                node_of(op, attempts, name),
                retry_policy=RetryPolicy(max_attempts=policy),
            )
        else:
            graph.add_node(name, node_of(op, attempts, name))
    worker = spec.get("worker")
    if worker is not None:
        graph.add_node("worker", node_of(worker, attempts, "worker"))
    for source, target in spec.get("edges", []):
        if source == "START":
            graph.add_edge(START, target)
        elif target == "END":
            graph.add_edge(source, END)
        else:
            graph.add_edge(source, target)
    for name, branch in routes.items():
        cases = branch.get("cases", [])
        default = branch.get("default", [])

        def routing(state: State, cases=cases, default=default) -> list[str]:
            for case in cases:
                if case["n_at_least"] <= state["n"]:
                    return case["to"]
            return default

        graph.add_conditional_edges(name, routing)
    return graph


def drain(stream: Any) -> list[dict[str, Any]]:
    """The completed-task sequence a run reports: one entry per finished task,
    with the writes it made (empty when it only routed)."""
    events: list[dict[str, Any]] = []
    for mode, chunk in stream:
        if mode != "updates":
            continue
        for name, update in chunk.items():
            if name == "__interrupt__":
                continue
            events.append({"node": name, "update": update or {}})
    return events


def snapshots_of(compiled: Any, config: Any) -> list[dict[str, Any]]:
    """One entry per checkpoint, oldest first: the state it holds, the tasks it
    says run next, which superstep it is, and whether it is waiting on an answer.

    The raw-input checkpoint LangGraph writes before `__start__` has no
    counterpart here, so it is dropped."""
    steps = []
    for snapshot in reversed(list(compiled.get_state_history(config))):
        if snapshot.next and list(snapshot.next) == ["__start__"]:
            continue
        interrupted = any(
            task.interrupts for task in (snapshot.tasks or ())
        )
        steps.append(
            {
                "values": snapshot.values,
                "next": list(snapshot.next),
                "step": snapshot.metadata.get("step"),
                "interrupted": interrupted,
            }
        )
    return steps


def trace(spec: dict[str, Any]) -> dict[str, Any]:
    attempts: dict[str, int] = {}
    compiled = build(spec, attempts).compile(checkpointer=InMemorySaver())
    config = {"configurable": {"thread_id": "t"}}
    limit = spec.get("limit", 25)
    run_config = dict(config, recursion_limit=limit)

    try:
        events = drain(
            compiled.stream(
                spec["input"], run_config, stream_mode=["updates", "values"]
            )
        )
    except Exception as error:  # noqa: BLE001 - a vector may record a failure
        return {"name": spec["name"], "error": type(error).__name__}

    state = compiled.get_state(config)
    interrupt_value = None
    if state.next and state.tasks and state.tasks[0].interrupts:
        interrupt_value = state.tasks[0].interrupts[0].value

    resumed = None
    if interrupt_value is not None:
        resumed = {
            "events": drain(
                compiled.stream(
                    Command(resume=spec["resume"]),
                    run_config,
                    stream_mode=["updates", "values"],
                )
            ),
            "final": compiled.get_state(config).values,
        }

    after = None
    rewrite = spec.get("after")
    if rewrite is not None:
        compiled.update_state(config, rewrite["write"], as_node=rewrite.get("as_node"))
        after = {
            "events": drain(
                compiled.stream(None, run_config, stream_mode=["updates", "values"])
            ),
            "final": compiled.get_state(config).values,
        }

    return {
        "name": spec["name"],
        "spec": spec,
        "events": events,
        "snapshots": None if after is not None else snapshots_of(compiled, config),
        "interrupt": interrupt_value,
        "resumed": resumed,
        "after": after,
        "attempts": attempts,
    }


def emit_data(vectors: list[dict[str, Any]]) -> str:
    text = json.dumps(vectors, indent=1, sort_keys=True)
    chunks: list[str] = []
    cursor = 0
    while cursor < len(text):
        stop = min(cursor + 900, len(text))
        if stop < len(text) and text[stop - 1] == "\\":
            # Never split an escape sequence across two literals.
            stop -= 1
        chunks.append(text[cursor:stop])
        cursor = stop
    lines = [
        "// Generated by scripts/gen_vectors.py from LangGraph 1.2.20. Do not edit.",
        "",
        "///|",
        "/// The differential vectors, one string per chunk: a single literal of this",
        "/// length is the kind of thing a wasm data segment does not care for.",
        "let vector_chunks : Array[String] = [",
    ]
    for chunk in chunks:
        lines.append(f"  {json.dumps(chunk)},")
    lines.append("]")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    specs = json.loads((ROOT / "vector_specs.json").read_text())
    vectors = [trace(spec) for spec in specs]
    text = json.dumps(vectors, indent=2, sort_keys=True) + "\n"
    data = emit_data(vectors)
    if "--check" in sys.argv:
        problems = []
        if not VECTORS.exists() or VECTORS.read_text() != text:
            problems.append(str(VECTORS))
        if not DATA.exists() or DATA.read_text() != data:
            problems.append(str(DATA))
        if problems:
            print("out of date: " + ", ".join(problems))
            return 1
        print(f"{len(vectors)} vectors match")
        return 0
    # Line feeds everywhere: the committed files are compared byte for byte.
    VECTORS.write_text(text, newline="\n")
    DATA.write_text(data, newline="\n")
    print(f"wrote {len(vectors)} vectors")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
