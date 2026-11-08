# moonstate

Durable state graphs for MoonBit: nodes, merging, checkpoints, interrupts and resume.
No model in sight.

A run is a sequence of supersteps. In each one a set of nodes runs, each returns the
updates it wants applied, and the updates are folded into the state in task order. Every
superstep is a checkpoint. When a process dies, the next run opens the last checkpoint
and continues from there; when a node asks a question, the run stops until it is answered.

```moonbit
#derive(@json.ToJson, @json.FromJson)
struct Counter {
  n : Int32
  log : Array[String]
}

#derive(@json.ToJson, @json.FromJson)
struct Patch {
  n : Int32?
  log : Array[String]?
}

fn merge(state : Counter, patch : Patch) -> Counter {
  { n: patch.n.unwrap_or(state.n), log: state.log + patch.log.unwrap_or([]) }
}

async fn hello() -> Counter raise {
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]) })]
    })
    .node("double", (state, _run) => {
      [@moonstate.Write({ n: Some(state.n * 2), log: None })]
    })
    .edge("seed", "double")
    .compile("hello")
  graph.run({ n: None, log: None })
}

async test "the first graph" {
  let out = hello() catch { error => abort((error : Error).to_string()) }
  assert_eq(out.n, 2)
  assert_eq(out.log, ["seed"])
}
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

The two types go through JSON, because a checkpoint stores the state and an executor that
ships a task elsewhere sends the input and receives the steps as JSON.
`#derive(@json.ToJson, @json.FromJson)` is enough for records of numbers, strings, lists
and other records.

A node writes only the fields it touched. `Patch` above does that with `Option`: `None`
leaves the field alone, which is what makes two nodes writing in one superstep mergeable
without knowing about each other.

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

```moonbit
#derive(@json.ToJson, @json.FromJson)
struct Report {
  parts : Array[Array[Int32]]
  total : Int32
}

#derive(@json.ToJson, @json.FromJson)
struct Part {
  value : Int32
}

fn report_merge(state : Report, part : Part) -> Report {
  { parts: state.parts + [[part.value]], total: state.total + part.value }
}

async fn fan_out() -> Report raise {
  let graph = @moonstate.Builder::new(merge=report_merge, initial={ parts: [], total: 0 })
    .entry("fan")
    .node("fan", (state, _run) => {
      let steps : Array[@moonstate.Step[Report, Part]] = []
      for index = 0; index < 3; index = index + 1 {
        steps.push(@moonstate.Send("shard", { parts: state.parts, total: index }))
      }
      steps
    })
    .node("shard", (state, _run) => {
      let steps : Array[@moonstate.Step[Report, Part]] = []
      steps.push(@moonstate.Write({ value: state.total * 10 }))
      steps
    })
    .routed("shard")
    .compile("fan")
  graph.run({ value: 0 })
}

async test "one node, three inputs" {
  let out = fan_out() catch { error => abort((error : Error).to_string()) }
  assert_eq(out.total, 30)
}
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

```moonbit
async fn durable() -> Array[String] raise {
  let saver = @moonstate.MemorySaver::new()
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]) })]
    })
    .node("double", (state, _run) => {
      [@moonstate.Write({ n: Some(state.n * 2), log: None })]
    })
    .edge("seed", "double")
    .compile("durable", saver=saver)
  let _ = graph.run({ n: None, log: None }, thread="job")
  let second = graph.run({ n: None, log: None }, thread="job")
  let history = graph.history("job")
  [second.n.to_string(), history.length().to_string(), history[2].id]
}

async test "a finished thread starts a new turn" {
  let out = durable() catch { error => abort((error : Error).to_string()) }
  assert_eq(out, ["2", "6", "cp-000002"])
}
```

- `put_writes` records a task's result as soon as it finishes, so a task that completed is
  not run twice after a crash, even when the rest of its superstep did not survive.
- `state(thread)` is the thread as it stands; `history(thread)` is every checkpoint it went
  through, oldest first, each one naming the checkpoint it was written on top of.
- `update(thread, patch, as_node=...)` writes into the latest state as if a node had written
  it, and queues what would have run after that node. A run afterwards continues from
  there, which is how a finished thread is taken back to an earlier decision.

`Saver` is a contract, not a database: five methods over records of JSON. `MemorySaver` is
the one that ships in this module.

## Checkpoints in a database

`moonbitstack/moonstate/sql` puts the same two services on any backend the database seam
speaks — SQLite, PostgreSQL and MySQL run the same code, and the SQL is written once
against the dialect the driver reports.

```moonbit
async fn [T : @moondb.AsyncDriver] on_a_database(
  connection : T,
) -> @moonstate.Graph[Counter, Patch] raise {
  let saver = @sql.saver(connection)
  // Creates the tables and their indexes when they are not there; safe to run on
  // every start.
  saver.setup()
  @moonstate.Builder::new(merge~, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]) })]
    })
    .compile("on-a-database", saver=saver)
}
```

`@sql.store(connection)` is the long-term memory on the same tables: namespaces, keys and
JSON, with a search over a namespace and everything below it.

Two things are worth knowing before pointing it at a server:

- **One connection, one saver.** The saver serialises its own statements, but a driver's
  connection carries one exchange at a time: a saver and a store that share a connection
  take turns, and two savers on one connection do not.
- **The dialect.** A driver that numbers its parameters reports `Dialect::Postgres` and the
  saver asks it. A driver that does not report its dialect builds the statements for
  SQLite's `?` and is refused by the server at the first statement; pass
  `dialect=@moondb.Dialect::Postgres` to `@sql.saver` in that case.
- **A driver that blocks.** SQLite's driver calls into C and implements the synchronous
  `Driver`; `@sql.blocking(connection)` is the bridge, and it is a bridge for any blocking
  driver, not a special case for SQLite.

## Interrupts

A node returns `Interrupt(payload)` to stop the run and wait. The run ends with
`GraphError::Interrupted`, the checkpoint carries the payload, and `resume_with` continues
the thread: the node that asked runs again and reads the answer from `Run::answer`.

```moonbit
async fn approve() -> Int32 raise {
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, log: [] })
    .entry("approve")
    .node("approve", (_state, run) => match run.answer() {
      Some(answer) => {
        let decided : Int32 = @json.from_json(answer)
        [@moonstate.Write({ n: Some(decided), log: None })]
      }
      None => [@moonstate.Interrupt({ "ask": "approve?" })]
    })
    .compile("approval", saver=@moonstate.MemorySaver::new())
  let stopped = try {
    let _ = graph.run({ n: None, log: None }, thread="review")
    "finished"
  } catch {
    @moonstate.GraphError::Interrupted(value~, ..) => value.stringify()
    _ => abort("the run failed for another reason")
  }
  assert_eq(stopped, "{\"ask\":\"approve?\"}")
  let out = graph.resume_with("review", Json(7))
  out.n
}

async test "a question stops the run and the answer continues it" {
  let out = approve() catch { error => abort((error : Error).to_string()) }
  assert_eq(out, 7)
}
```

The tasks of the interrupted superstep whose writes were already applied are kept; the
interrupting task is not recorded, so it runs again instead of replaying its own question.

## Where the tasks run

An `Executor` decides where a superstep's tasks run. The engine hands it the whole
superstep, so a fan-out is parallel, and takes the results back in the order it gave them.

`@moonstate.inline` is the default: every task in this process, at the same time. An
executor is a trait with one method, `each`, so a different policy is a small type:

```moonbit
struct OneAtATime {}

pub impl @moonstate.Executor for OneAtATime with fn each(_self, works) {
  let done : Array[@moonstate.Done] = []
  for work in works {
    let outcome = try {
      Ok((work.run)())
    } catch {
      error => Err(error)
    }
    done.push(match outcome {
      Ok(values) => @moonstate.Done::{ values: Some(values), error: None }
      Err(error) =>
        @moonstate.Done::{ values: None, error: Some((error : Error).to_string()) }
    })
  }
  done
}

// The trait's method is not promoted to a plain method of the type: call it
// through the trait, which is what the engine does.
pub extend OneAtATime with @moonstate.Executor::{each}

async fn one_at_a_time() -> Int32 raise {
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(5), log: None })])
    .compile("serial", executor=OneAtATime::{})
  let out = graph.run({ n: None, log: None })
  out.n
}

async test "an executor of one's own" {
  let out = one_at_a_time() catch { error => abort((error : Error).to_string()) }
  assert_eq(out, 5)
}
```

`Work` carries the graph name, the node name, the thread, the step and the attempt, plus two
functions: `input` encodes the state only when it is asked for, and `run` is what an
in-process executor calls. An executor that ships the task elsewhere ignores `run` and finds
the node by name on the far side; `Done` comes back as JSON either way.

## Traces

`moonbitstack/moonstate/otel` wraps an executor so that every superstep and every node in it
is a span, named with the OpenTelemetry GenAI semantic conventions:

```moonbit
fn clock() -> Int64 {
  @env.now().reinterpret_as_int64() * 1_000_000L
}

fn random_bytes(width : Int32) -> Bytes {
  match @env.rand(width) {
    Some(bytes) => bytes
    None => abort("the platform has no entropy source")
  }
}

async fn traced_run() -> Array[String] raise {
  let spans = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=random_bytes,
    sink=spans,
    sampler=@trace.parent_based(root=@trace.always),
  )
  let executor = @otel.traced(@moonstate.inline, tracer~, now=clock)
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(2), log: None })])
    .compile("traced", executor=executor)
  let _ = graph.run({ n: None, log: None })
  spans.spans().map(span => span.name)
}

async test "a run is a tree of spans" {
  let names = traced_run() catch { error => abort((error : Error).to_string()) }
  assert_eq(names, ["seed", "superstep 0"])
}
```

A trace follows a thread from superstep to superstep: each superstep span is a child of the
previous one, so a run is one trace however many supersteps it takes, and a node's span sits
under the superstep that ran it. The span names come from the conventions rather than from
this library: `gen_ai.operation.name` is `invoke_agent` on a superstep and `execute_tool` on
a node, `gen_ai.agent.name` is the graph, `gen_ai.tool.name` is the node, and
`gen_ai.conversation.id` is the thread. Message payloads are never recorded.

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

## Documentation

The site is <https://moonbitstack.github.io/moonstate/>: an instrument that runs this library in
the browser (a ring of the twenty-five supersteps a run may take, the checkpoints as notches, a demo
that plays itself in six stages, and a last stage that reloads the tab mid-run), a guide that walks the same path the code does, and the
reference generated from the interface files. Every block on the guide is the README's block,
compiled by CI; every page follows the reader's light or dark setting, and the setting follows the
system until the reader chooses one.

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
| `@sql.saver(driver, names?, dialect?)` | Checkpoints in SQLite, PostgreSQL or MySQL. |
| `@sql.store(driver, names?, dialect?)` | Long-term memory on the same tables. |
| `@sql.blocking(driver)` | A blocking driver, as one the saver can await. |
| `@otel.traced(executor, tracer~, now~)` | An executor that reports spans. |

## Conformance

The behaviour is pinned by 24 graphs — a line, fan-outs, joins, cycles, branches, `Send`,
`Goto`, retries, interrupts with resume, subgraphs and time travel — replayed against
vectors generated from LangGraph 1.2.20 by `scripts/gen_vectors.py`. For each graph the
suite compares the sequence of finished nodes and what each wrote, the state after every
superstep, the interrupt payload, the resumed run, and the state a rewrite produces. 88
checkpoints are compared one by one: the state each holds, the tasks it says run next, its
superstep number, and whether it is waiting on an answer. All of them match.

The checkpoint scenarios — an interrupt and its answer, a task whose neighbour failed, a
page of history, a rewrite, a deleted thread, and long-term memory — run against the
in-memory saver, SQLite, PostgreSQL and MySQL in `integration/`, and the transcripts have to
match line for line. The spans of a run are checked against the OpenTelemetry semantic
conventions registry by `weaver registry live-check` in CI: the names on them are the
conventions' names, and a name this library invented would fail the job. Against the GenAI
registry the eight spans of the example raise 28 advisories and no violation; every one of
the 28 says an attribute is at `development` stability, which is the state of that family of
conventions rather than anything about the name.

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
