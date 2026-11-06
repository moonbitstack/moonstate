---
name: moonstate
description: Durable state graphs for MoonBit — build a graph of nodes over your own state, run it in supersteps, checkpoint every step, and resume after a crash or an interrupt. Use when a workflow has to survive a process ending, wait for a human answer, or fan work out over several tasks and merge the results deterministically.
---

# moonstate

A run is a sequence of supersteps: a set of nodes runs, each returns the updates it wants,
and the updates fold into the state in task order. Every superstep is a checkpoint.

## Install

```toml
[dependencies]
"moonbitstack/moonstate" = "0.1.0"
"moonbitlang/async" = "0.22.5"
```

```moonbit
import { "moonbitstack/moonstate" }
```

## A graph, and what it needs from you

The state `S` and the update `U` are your types, and both go through JSON, because a
checkpoint stores the state and an executor that ships a task elsewhere sends it as JSON.

```moonbit
#derive(@json.ToJson, @json.FromJson)
struct Counter {
  n : Int
  log : Array[String]
}

pub extend Counter with @json.ToJson::{to_json}

pub extend Counter with @json.FromJson::{from_json}

#derive(@json.ToJson, @json.FromJson)
struct Patch {
  n : Int?
  log : Array[String]?
}

pub extend Patch with @json.ToJson::{to_json}

pub extend Patch with @json.FromJson::{from_json}

fn merge(state : Counter, patch : Patch) -> Counter {
  { n: patch.n.unwrap_or(state.n), log: state.log + patch.log.unwrap_or([]) }
}
```

A node returns steps, not a new state: `Write(U)`, `Goto(node)`, `Send(node, S)`, or
`Interrupt(Json)`.

```moonbit
let graph = @moonstate.Builder::new(merge=merge, initial={ n: 0, log: [] })
  .entry("seed")
  .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(1), log: Some(["seed"]) })])
  .node("double", (state, _run) => [@moonstate.Write({ n: Some(state.n * 2), log: None })])
  .edge("seed", "double")
  .compile("hello")
```

## Durable runs

Compile with a `Saver`, pass a `thread` to `run`, and a second `run` on the same thread
continues from the last checkpoint instead of starting over.

```moonbit
let saver = @moonstate.MemorySaver::new()
let graph = build(saver)
let _ = graph.run(input, thread="job")      // dies halfway
let out = graph.run(input, thread="job")    // continues where it stopped
```

The same handles also cover the rest of a durable workflow:

- `graph.state("job")` — the thread as it stands, and `graph.history("job")` — every
  checkpoint it took.
- `graph.update("job", patch, as_node="double")` — rewrite the latest state as if that node
  had written it, then run what follows it.
- `graph.resume_with("job", answer)` — continue a thread whose node returned `Interrupt`.

`MemorySaver` keeps checkpoints in the process. For anything that has to outlive the
process, implement `Saver`: five methods over records of JSON.

## Interrupts

```moonbit
.node("approve", (_state, run) => match run.answer() {
  Some(answer) => [@moonstate.Write({ approved: Some(@json.from_json(answer)), text: None })],
  None => [@moonstate.Interrupt({ "ask": "approve?" })],
})
```

`run` ends with `GraphError::Interrupted`; `resume_with` runs the node again, and the answer
comes back through `run.answer()`.

## Fan-out

`Send` queues a node once per input; the tasks run in one superstep and merge in the order
they were queued. A node entered only by `Send` has to be declared with `routed`, or
`compile` refuses the graph as unreachable.

```moonbit
.node("fan", (_state, _run) => {
  let steps : Array[@moonstate.Step[Report, Part]] = []
  for shard = 0; shard < 4; shard = shard + 1 {
    steps.push(@moonstate.Send("score", { shard, hits: None }))
  }
  steps
})
.node("score", (state, _run) => [@moonstate.Write({ shard: None, hits: Some(1) })])
.routed("score")
```

## Things that catch people out

- Both `S` and `U` must implement `@json.ToJson` and `@json.FromJson`; without them `run`
  does not compile.
- `compile` refuses a graph with an edge to a node that is not defined, a node nothing
  reaches, or no node that ends it. Use `routed` for nodes entered at run time.
- A node that runs elsewhere never sees `Run`; take what a node needs from the state, and
  put the answer back with `Write`.
- `Send` gives a task its own input state, but that input is not merged back: the task has
  to write whatever the state should keep.
- A run stops after 25 supersteps unless `compile` is given another `limit`; a cycle needs a
  branch that leaves it.
