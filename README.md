# moonstate

Durable state graphs for MoonBit: nodes, merging, checkpoints, interrupts and resume.
No model in sight.

A run is a sequence of supersteps. In each one a set of nodes runs, each returns the
updates it wants applied, and the updates are folded into the state in task order. Every
superstep is a checkpoint. When a process dies, the next run opens the last checkpoint
and continues from there; when a node asks a question, the run stops until it is answered.

<!-- nocheck -->

```moonbit
let graph = @moonstate.Builder::new(merge=merge, initial={ n: 0, log: [] })
  .entry("seed")
  .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(1), log: Some(["seed"]) })])
  .node("double", (state, _run) => [@moonstate.Write({ n: Some(state.n * 2), log: None })])
  .edge("seed", "double")
  .compile("hello")

let out = graph.run({ n: None, log: None })
// out.n == 2
```

## Install

<!-- nocheck -->

```toml
[dependencies]
"moonbitstack/moonstate" = "0.1.0"
```

<!-- nocheck -->

```moonbit
import { "moonbitstack/moonstate" }
```

Add `moonbitlang/async` to the project as well: a run is asynchronous, and the executor
runs a superstep's tasks at the same time.

## The state and the update

The graph is written over two types of yours: the state `S`, and the update `U` a node
writes. Merging is a function, `merge : (S, U) -> S`, so a run's result does not depend on
the order the executor happened to finish the tasks in: the engine folds the writes in task
order, and a task order is the order the nodes were queued.

<!-- nocheck -->

```moonbit
struct Counter { n : Int; log : Array[String] }

struct Patch { n : Int?; log : Array[String]? }

fn merge(state : Counter, patch : Patch) -> Counter {
  { n: patch.n.unwrap_or(state.n), log: state.log + patch.log.unwrap_or([]) }
}
```

Both types go through JSON: a checkpoint stores the state, and an executor that ships a task
elsewhere sends the input and receives the steps as JSON. `#derive(@json.ToJson,
@json.FromJson)` is enough for records of numbers, strings, lists and other records.

## Supersteps

A superstep runs the nodes that are queued, merges what they wrote, and then decides what to
run next:

- an **edge** `a -> b` queues `b` after `a`;
- a **join** `["a", "b"] -> c` is a gate: `c` runs only when both wrote in the same
  superstep;
- a **branch** is called with the state as merged at the end of the superstep and returns
  the nodes to queue;
- `Goto` inside a node replaces the edges that node declared;
- `Send` queues a node once per input, each with its own state.

A node may return several steps; they are applied in the order it wrote them.

<!-- nocheck -->

```moonbit
.node("fan", (_state, _run) => {
  let steps : Array[@moonstate.Step[Report, Part]] = []
  for index = 0; index < 3; index = index + 1 {
    steps.push(@moonstate.Send("shard", { parts: [], total: index }))
  }
  steps
})
.node("shard", (state, _run) => [@moonstate.Write({ parts: Some([...]), total: None })])
.routed("shard")   // entered by Send, not by an edge
```

`compile` refuses a graph that could not run: an edge to a node that is not defined, a node
nothing reaches, a graph whose every node has a successor, the same node name twice. A node
entered at run time — by `Send`, `Goto` or a route — is declared with `routed`, so the check
does not mistake it for dead code.

The number of supersteps a run may take is `default_limit`, 25 unless `compile` is given
another number. A cycle that never leaves itself stops with `StepLimit` rather than hanging.

## Checkpoints

Compile with a `Saver` and every superstep is written down before it runs. The next run on
the same thread opens the last checkpoint instead of starting over.

<!-- nocheck -->

```moonbit
let saver = @moonstate.MemorySaver::new()
let graph = build(saver)                    // compile(..., saver=saver)

let _ = graph.run(input, thread="job")      // dies halfway
let out = graph.run(input, thread="job")    // continues from the last superstep
```

- `put_writes` records a task's result as soon as it finishes, so a task that completed is
  not run twice after a crash, even when the rest of its superstep did not survive.
- `state(thread)` is the thread as it stands; `history(thread)` is every checkpoint it went
  through, oldest first.
- `update(thread, patch, as_node=...)` writes into the latest state as if a node had written
  it, and queues what would have run after that node. A run afterwards continues from
  there, which is how a finished thread is taken back to an earlier decision.

`Saver` is a contract, not a database: five methods over records of JSON. `MemorySaver` is
the one that ships; an implementation on disk is about a hundred lines, and the durable
example is one.

## Interrupts

A node returns `Interrupt(payload)` to stop the run and wait. The run ends with
`GraphError::Interrupted`, the checkpoint carries the payload, and `resume_with` continues
the thread: the node that asked runs again and reads the answer from `Run::answer`.

<!-- nocheck -->

```moonbit
.node("approve", (_state, run) => match run.answer() {
  Some(answer) => [@moonstate.Write({ approved: Some(@json.from_json(answer)) , text: None })],
  None => [@moonstate.Interrupt({ "ask": "approve?" })],
})
```

<!-- nocheck -->

```moonbit
let out = graph.resume_with("review", Json(true))
```

The tasks of the interrupted superstep whose writes were already applied are kept; the
interrupting task is not recorded, so it runs again instead of replaying its own question.

## Where the tasks run

An `Executor` decides where a superstep's tasks run. The engine hands it the whole
superstep, so a fan-out is parallel, and takes the results back in the order it gave them.

<!-- nocheck -->

```moonbit
pub(open) trait Executor {
  async each(Self, Array[Work]) -> Array[Done] raise
}
```

`Work` carries the graph name, the node name, the thread, the step and the attempt, plus two
functions: `input` encodes the state only when it is asked for, and `run` is what an
in-process executor calls. An executor that ships the task elsewhere ignores `run` and finds
the node by name on the far side; `Done` comes back as JSON either way.

`inline` is the default: every task in this process, at the same time. The process example
runs each task in a child of the same binary, which is enough to show the contract holds
across a process boundary.

## Functional form

A function with durable steps instead of a graph:

<!-- nocheck -->

```moonbit
let fetch = @moonstate.task("fetch", async fn(url : String) -> String { ... })
let score = @moonstate.task("score", async fn(text : String) -> Int { ... })

let workflow = @moonstate.entrypoint("rank", async fn(url : String, ctx : @moonstate.Context) -> Int {
  let text = fetch.call(ctx, url)
  score.call(ctx, text)
}, saver=saver)
```

Each `call` is recorded when it finishes. A run that dies replays the entrypoint from the
start — the body has to be deterministic apart from the task calls — and the calls that
already finished return their recorded result instead of running again. A task takes a
`retry` policy the way a node does.

## Around a run

`Run` is what a node is handed besides the state: the thread, the superstep, the checkpoint
its writes belong to, the long-term `Store`, `emit` for progress, and `cancel`.

`stream` reports events as they happen: `Started` and `Finished` per node, `Updates` per
write, `Values` after a superstep, `Custom` for what a node emitted, `Interrupted` when the
run stops to ask. `run` is `stream` without a listener.

Cancelling stops the thread at the next superstep boundary, never inside a node, so what a
node wrote before asking to stop is kept.

## API

| Item | Purpose |
|:--|:--|
| `Builder::new(merge~, initial~)` | The empty state, and how an update folds into it. |
| `Builder::node(name, run, retry?)` | A node: state and `Run` in, steps out. |
| `Builder::edge(from, to)` | Run `to` after `from`. |
| `Builder::join(from, to)` | Run `to` once every node in `from` ran in the same superstep. |
| `Builder::branch(from, route)` | `route` picks the next nodes from the merged state. |
| `Builder::subgraph(name, graph, enter~, leave~)` | A whole graph as one node. |
| `Builder::routed(name)` | `name` is entered by `Send`, `Goto` or a route. |
| `Builder::entry(name)` | The node a run starts at. |
| `Builder::compile(name, saver?, store?, executor?, limit?)` | Check the graph and freeze it. |
| `Step` | `Write`, `Goto`, `Send`, `Interrupt`: what a node returns. |
| `Graph::run(input, thread?)` | Run to the end, or continue a crashed thread. |
| `Graph::stream(input, on, thread?)` | The same, reporting events. |
| `Graph::resume_with(thread, answer)` | Continue a thread that is waiting. |
| `Graph::resume_stream(thread, answer, on)` | The same, reporting events. |
| `Graph::state(thread)` / `Graph::history(thread)` | The thread now, and every checkpoint it took. |
| `Graph::update(thread, patch, as_node?)` | Rewrite the latest state, then continue after a node. |
| `Saver` / `MemorySaver` | Where checkpoints live. |
| `Store` / `MemoryStore` | Long-term memory: namespaced JSON with a search. |
| `Executor` / `inline` | Where a superstep's tasks run. |
| `Run` | Thread, step, checkpoint, store, emit, cancel. |
| `task` / `entrypoint` / `Task` / `Context` | The functional form. |

## Conformance

The behaviour is pinned by 24 graphs — a line, fan-outs, joins, cycles, branches, `Send`,
`Goto`, retries, interrupts with resume, subgraphs and time travel — replayed against
vectors generated from LangGraph 1.2.20 by `scripts/gen_vectors.py`. For each graph the
suite compares the sequence of finished nodes and what each wrote, the state after every
superstep, the interrupt payload, the resumed run, and the state a rewrite produces. All 24
match.

Two behaviours are deliberately different, and are not in the vectors:

- **A write conflict.** Two tasks writing the same field in one superstep is an error there
  and a fold in task order here. Merging is a function of `(S, U)` in this library, so a
  conflict is always resolvable and always deterministic.
- **A join across supersteps.** A node fed by two others runs once per trigger there; here
  `join` holds it until both upstream nodes ran in the same superstep, which is what makes a
  diamond run its join once.

The tests run on every backend; the asynchronous ones are skipped on wasm-gc, whose test
driver does not run asynchronous tests. `scripts/kill_test.sh` runs the durable example,
kills it mid-run, and checks that the restarted run continues from its checkpoint.
