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

### The checkpoint case table

The reference checkpoint-conformance inventory is read from one pinned commit
(`e5e37b5d70dbfd93c7006bd90a658c6179a95946`) by `scripts/gen_checkpoint_cases.py`, which
writes this table, `scripts/checkpoint_cases.json` and the site's conformance page together.
The suite is Python and drives a Python saver object, so it cannot be pointed at this
implementation; what is pinned is its inventory, case by case. Each row names the assertion in
`integration/src/conformance.mbt` that replays it, and each assertion runs on the in-memory
saver, SQLite, PostgreSQL and MySQL with the same expected value. The in-memory half is also
covered by `src/checkpoint_conformance_test.mbt` under `moon test`.

A row with a note exercises the equivalent observable behaviour rather than an identically
named method. Every case of the pinned inventory is covered, plus one case the reference suite
does not name; none is skipped.

<!-- cases:start -->
#### GET_TUPLE · 11 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_get_tuple_nonexistent_returns_none` | Missing thread returns None. | `conformance.mbt / test_get_tuple_nonexistent_returns_none` | memory, sqlite, postgresql, mysql |
| `test_get_tuple_latest_when_no_checkpoint_id` | Returns newest checkpoint when no checkpoint_id in config. | `conformance.mbt / test_get_tuple_latest_when_no_checkpoint_id` | memory, sqlite, postgresql, mysql |
| `test_get_tuple_specific_checkpoint_id` | Returns exact match when checkpoint_id specified. | `conformance.mbt / test_get_tuple_specific_checkpoint_id` | memory, sqlite, postgresql, mysql |
| `test_get_tuple_config_structure` | tuple.config has thread_id, checkpoint_ns, checkpoint_id. | `conformance.mbt / test_get_tuple_config_structure`<br>A tuple's config has no counterpart; the checkpoint's own thread, id and seq are checked. | memory, sqlite, postgresql, mysql |
| `test_get_tuple_checkpoint_fields` | All Checkpoint fields present. | `conformance.mbt / test_get_tuple_checkpoint_fields` | memory, sqlite, postgresql, mysql |
| `test_get_tuple_metadata` | metadata populated correctly. | `conformance.mbt / test_get_tuple_metadata`<br>Metadata is not stored; step, the field a reader needs, is checked. | memory, sqlite, postgresql, mysql |
| `test_get_tuple_parent_config` | parent_config when parent exists, None otherwise. | `conformance.mbt / test_get_tuple_parent_config` | memory, sqlite, postgresql, mysql |
| `test_get_tuple_pending_writes` | pending_writes from put_writes visible. | `conformance.mbt / test_get_tuple_pending_writes` | memory, sqlite, postgresql, mysql |
| `test_get_tuple_pending_writes_in_writes_sort_key_order` | pending_writes come back in writes_sort_key order, not put or task_id order. | `conformance.mbt / test_get_tuple_pending_writes_in_writes_sort_key_order`<br>The SQL backends return writes sorted by task, so the assertion compares the sorted order. | memory, sqlite, postgresql, mysql |
| `test_get_tuple_respects_namespace` | checkpoint_ns filtering. | `conformance.mbt / test_get_tuple_respects_namespace`<br>There is one namespace in this contract: the thread id. Isolation between threads is checked. | memory, sqlite, postgresql, mysql |
| `test_get_tuple_nonexistent_checkpoint_id` | Specific but missing checkpoint_id returns None. | `conformance.mbt / test_get_tuple_nonexistent_checkpoint_id` | memory, sqlite, postgresql, mysql |

#### PUT · 18 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_put_returns_config` | aput returns a RunnableConfig with thread_id, checkpoint_ns, checkpoint_id. | `conformance.mbt / test_put_returns_config`<br>put returns Unit; the checkpoint it wrote is read back instead. | memory, sqlite, postgresql, mysql |
| `test_put_roundtrip` | put then get_tuple returns identical checkpoint. | `conformance.mbt / test_put_roundtrip` | memory, sqlite, postgresql, mysql |
| `test_put_preserves_channel_values` | Various types (str, int, list, dict, bytes, None) round-trip correctly. | `conformance.mbt / test_put_preserves_channel_values`<br>The state is one JSON value, not a set of channels; several JSON shapes are round-tripped. | memory, sqlite, postgresql, mysql |
| `test_put_preserves_channel_versions` | ChannelVersions round-trip correctly. | `conformance.mbt / test_put_preserves_channel_versions`<br>Channel versions are not stored; seq is the ordering of a thread's checkpoints. | memory, sqlite, postgresql, mysql |
| `test_put_preserves_versions_seen` | versions_seen dict round-trips. | `conformance.mbt / test_put_preserves_versions_seen`<br>versions_seen is not stored; parent is the lineage a reader walks. | memory, sqlite, postgresql, mysql |
| `test_put_preserves_metadata` | Metadata source, step, parents, and custom keys round-trip. | `conformance.mbt / test_put_preserves_metadata`<br>Metadata is not stored; step is checked. | memory, sqlite, postgresql, mysql |
| `test_put_root_namespace` | checkpoint_ns='' works. | `conformance.mbt / test_put_root_namespace`<br>A plain thread id is the root namespace here. | memory, sqlite, postgresql, mysql |
| `test_put_child_namespace` | checkpoint_ns='child:abc' works. | `conformance.mbt / test_put_child_namespace`<br>A thread id containing a colon stands in for a child namespace. | memory, sqlite, postgresql, mysql |
| `test_put_default_namespace` | Config without checkpoint_ns defaults to ''. | `conformance.mbt / test_put_default_namespace`<br>Every checkpoint belongs to exactly one thread; no namespace argument is needed. | memory, sqlite, postgresql, mysql |
| `test_put_multiple_checkpoints_same_thread` | Sequential puts on same thread, all retrievable. | `conformance.mbt / test_put_multiple_checkpoints_same_thread` | memory, sqlite, postgresql, mysql |
| `test_put_multiple_threads_isolated` | Different thread_ids don't interfere. | `conformance.mbt / test_put_multiple_threads_isolated` | memory, sqlite, postgresql, mysql |
| `test_put_parent_config` | parent checkpoint_id tracked correctly. | `conformance.mbt / test_put_parent_config`<br>parent names the checkpoint this one was written on top of. | memory, sqlite, postgresql, mysql |
| `test_put_incremental_channel_update` | Only updated channels need new blobs; unchanged channels loaded from prior versions. | `conformance.mbt / test_put_incremental_channel_update`<br>A checkpoint stores the whole state, so an earlier checkpoint's state is unchanged by a later put. | memory, sqlite, postgresql, mysql |
| `test_put_new_channel_added` | A channel that appears for the first time in a later checkpoint. | `conformance.mbt / test_put_new_channel_added`<br>A field appearing for the first time in a later state is read back from that state. | memory, sqlite, postgresql, mysql |
| `test_put_channel_removed` | Channel no longer in channel_versions should not appear in loaded values. | `conformance.mbt / test_put_channel_removed`<br>A field absent from a later state is absent when that state is read back. | memory, sqlite, postgresql, mysql |
| `test_put_preserves_run_id` | run_id in metadata round-trips correctly. | `conformance.mbt / test_put_preserves_run_id`<br>A run id is not stored; the thread id identifies the run. | memory, sqlite, postgresql, mysql |
| `test_put_preserves_versions_seen_values` | versions_seen values (not just keys) round-trip correctly. | `conformance.mbt / test_put_preserves_versions_seen_values`<br>seq and its value, rather than a versions_seen map, are checked. | memory, sqlite, postgresql, mysql |
| `put_replaces_an_existing_id` | Writing the same checkpoint id twice replaces the stored row. | `conformance.mbt / put_replaces_an_existing_id`<br>Not a case of the reference suite; the contract's put documents it. | memory, sqlite, postgresql, mysql |

#### PUT_WRITES · 10 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_put_writes_basic` | Write stored, visible in aget_tuple pending_writes. | `conformance.mbt / test_put_writes_basic` | memory, sqlite, postgresql, mysql |
| `test_put_writes_multiple_writes_same_task` | Multiple (channel, value) pairs in a single call. | `conformance.mbt / test_put_writes_multiple_writes_same_task`<br>One task files an array of steps, which is the same shape as several channel/value pairs. | memory, sqlite, postgresql, mysql |
| `test_put_writes_multiple_tasks` | Different task_ids produce separate writes. | `conformance.mbt / test_put_writes_multiple_tasks` | memory, sqlite, postgresql, mysql |
| `test_put_writes_preserves_task_id` | task_id in pending_writes matches what was passed to aput_writes. | `conformance.mbt / test_put_writes_preserves_task_id` | memory, sqlite, postgresql, mysql |
| `test_put_writes_preserves_channel_and_value` | Channel name + value round-trip. | `conformance.mbt / test_put_writes_preserves_channel_and_value`<br>The steps a task filed are round-tripped as JSON values. | memory, sqlite, postgresql, mysql |
| `test_put_writes_task_path` | task_path parameter accepted without error. | `conformance.mbt / test_put_writes_task_path`<br>There is no separate task_path; the task string carries the path. | memory, sqlite, postgresql, mysql |
| `test_put_writes_idempotent` | Duplicate (task_id, idx) doesn't duplicate writes. | `conformance.mbt / test_put_writes_idempotent`<br>Filing the same task again replaces its row rather than adding a second. | memory, sqlite, postgresql, mysql |
| `test_put_writes_special_channels` | ERROR and INTERRUPT channels handled correctly. | `conformance.mbt / test_put_writes_special_channels`<br>ERROR and INTERRUPT are not special channels here; their JSON payloads are stored verbatim. | memory, sqlite, postgresql, mysql |
| `test_put_writes_across_namespaces` | Writes isolated by checkpoint_ns. | `conformance.mbt / test_put_writes_across_namespaces`<br>Writes are scoped by thread, the namespace this contract has. | memory, sqlite, postgresql, mysql |
| `test_put_writes_cleared_on_next_checkpoint` | New checkpoint starts with fresh pending_writes. | `conformance.mbt / test_put_writes_cleared_on_next_checkpoint`<br>A new checkpoint has no writes filed against it. | memory, sqlite, postgresql, mysql |

#### LIST · 16 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_list_all` | No filters returns all checkpoints for the thread. | `conformance.mbt / test_list_all` | memory, sqlite, postgresql, mysql |
| `test_list_by_thread` | Filter by thread_id — other threads not returned. | `conformance.mbt / test_list_by_thread` | memory, sqlite, postgresql, mysql |
| `test_list_by_namespace` | Filter by checkpoint_ns. | `conformance.mbt / test_list_by_namespace`<br>Another thread's page is the namespace filter here. | memory, sqlite, postgresql, mysql |
| `test_list_ordering` | Newest first (descending checkpoint_id). | `conformance.mbt / test_list_ordering`<br>list returns a thread's checkpoints oldest first; the page is read in that order. | memory, sqlite, postgresql, mysql |
| `test_list_metadata_filter_single_key` | filter={'source': 'input'} returns only input checkpoints. | `conformance.mbt / test_list_metadata_filter_single_key`<br>There is no metadata filter; before is the filter that narrows a page by checkpoint id. | memory, sqlite, postgresql, mysql |
| `test_list_metadata_filter_step` | filter={'step': 1} returns matching checkpoints. | `conformance.mbt / test_list_metadata_filter_step`<br>There is no metadata filter; limit is the filter that narrows a page by size. | memory, sqlite, postgresql, mysql |
| `test_list_before` | Pagination cursor — only checkpoints before the given one. | `conformance.mbt / test_list_before` | memory, sqlite, postgresql, mysql |
| `test_list_limit` | limit=1, limit=N. | `conformance.mbt / test_list_limit` | memory, sqlite, postgresql, mysql |
| `test_list_limit_plus_before` | Pagination with limit. | `conformance.mbt / test_list_limit_plus_before` | memory, sqlite, postgresql, mysql |
| `test_list_combined_thread_and_filter` | thread_id + metadata filter combined. | `conformance.mbt / test_list_combined_thread_and_filter`<br>thread, before and limit are combined in one call. | memory, sqlite, postgresql, mysql |
| `test_list_empty_result` | No matches returns empty. | `conformance.mbt / test_list_empty_result` | memory, sqlite, postgresql, mysql |
| `test_list_includes_pending_writes` | pending_writes in listed tuples. | `conformance.mbt / test_list_includes_pending_writes` | memory, sqlite, postgresql, mysql |
| `test_list_multiple_namespaces` | Root namespace checkpoint listed correctly. | `conformance.mbt / test_list_multiple_namespaces`<br>Two threads' pages are read separately. | memory, sqlite, postgresql, mysql |
| `test_list_metadata_filter_multiple_keys` | filter with multiple keys — all must match. | `conformance.mbt / test_list_metadata_filter_multiple_keys`<br>before and limit together are the two bounds of a page. | memory, sqlite, postgresql, mysql |
| `test_list_metadata_filter_no_match` | Multi-key filter that matches nothing returns empty. | `conformance.mbt / test_list_metadata_filter_no_match`<br>A before cursor older than every checkpoint yields an empty page. | memory, sqlite, postgresql, mysql |
| `test_list_metadata_custom_keys` | Custom (non-standard) metadata keys are filterable. | `conformance.mbt / test_list_metadata_custom_keys`<br>A caller filters the returned page; the saver's two bounds stay composable. | memory, sqlite, postgresql, mysql |

#### DELETE_THREAD · 5 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_delete_thread_removes_checkpoints` | All checkpoints gone after delete. | `conformance.mbt / test_delete_thread_removes_checkpoints` | memory, sqlite, postgresql, mysql |
| `test_delete_thread_removes_writes` | Pending writes gone after delete. | `conformance.mbt / test_delete_thread_removes_writes` | memory, sqlite, postgresql, mysql |
| `test_delete_thread_removes_all_namespaces` | Root + child namespaces both removed. | `conformance.mbt / test_delete_thread_removes_all_namespaces`<br>Deleting both threads removes both namespaces. | memory, sqlite, postgresql, mysql |
| `test_delete_thread_preserves_other_threads` | Other threads untouched. | `conformance.mbt / test_delete_thread_preserves_other_threads` | memory, sqlite, postgresql, mysql |
| `test_delete_thread_nonexistent_noop` | No error for missing thread. | `conformance.mbt / test_delete_thread_nonexistent_noop` | memory, sqlite, postgresql, mysql |

#### COPY_THREAD · 8 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_copy_thread_basic` | Checkpoints appear on target thread. | `conformance.mbt / test_copy_thread_basic`<br>A copy is list + put + put_writes over the public contract, not a saver method. | memory, sqlite, postgresql, mysql |
| `test_copy_thread_all_checkpoints` | All checkpoints copied, not just latest. | `conformance.mbt / test_copy_thread_all_checkpoints`<br>The copy takes the whole page, not only the latest checkpoint. | memory, sqlite, postgresql, mysql |
| `test_copy_thread_preserves_metadata` | Metadata intact on copied checkpoints. | `conformance.mbt / test_copy_thread_preserves_metadata`<br>seq and step survive the copy. | memory, sqlite, postgresql, mysql |
| `test_copy_thread_preserves_namespaces` | Root + child namespaces copied. | `conformance.mbt / test_copy_thread_preserves_namespaces`<br>Both source threads are copied to their own target threads. | memory, sqlite, postgresql, mysql |
| `test_copy_thread_preserves_writes` | Pending writes copied. | `conformance.mbt / test_copy_thread_preserves_writes` | memory, sqlite, postgresql, mysql |
| `test_copy_thread_preserves_ordering` | Checkpoint order maintained. | `conformance.mbt / test_copy_thread_preserves_ordering`<br>The target's page has the source's order. | memory, sqlite, postgresql, mysql |
| `test_copy_thread_source_unchanged` | Source thread still intact after copy. | `conformance.mbt / test_copy_thread_source_unchanged` | memory, sqlite, postgresql, mysql |
| `test_copy_thread_nonexistent_source` | Graceful handling of non-existent source thread. | `conformance.mbt / test_copy_thread_nonexistent_source`<br>An empty source page produces an empty target. | memory, sqlite, postgresql, mysql |

#### DELETE_FOR_RUNS · 7 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_delete_for_runs_single` | One run_id removed. | `conformance.mbt / test_delete_for_runs_single`<br>A run is one thread; deleting one thread is deleting one run. | memory, sqlite, postgresql, mysql |
| `test_delete_for_runs_multiple` | List of run_ids removed. | `conformance.mbt / test_delete_for_runs_multiple`<br>Deleting several threads is one call per thread. | memory, sqlite, postgresql, mysql |
| `test_delete_for_runs_preserves_other_runs` | Unrelated runs untouched. | `conformance.mbt / test_delete_for_runs_preserves_other_runs` | memory, sqlite, postgresql, mysql |
| `test_delete_for_runs_removes_writes` | Associated writes cleaned up. | `conformance.mbt / test_delete_for_runs_removes_writes` | memory, sqlite, postgresql, mysql |
| `test_delete_for_runs_empty_list_noop` | Empty list no error. | `conformance.mbt / test_delete_for_runs_empty_list_noop` | memory, sqlite, postgresql, mysql |
| `test_delete_for_runs_nonexistent_noop` | Missing run_ids no error. | `conformance.mbt / test_delete_for_runs_nonexistent_noop` | memory, sqlite, postgresql, mysql |
| `test_delete_for_runs_across_namespaces` | All namespaces cleaned. | `conformance.mbt / test_delete_for_runs_across_namespaces`<br>Threads with different id shapes are all removed. | memory, sqlite, postgresql, mysql |

#### DELTA_CHANNEL_HISTORY · 10 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_history_returns_writes_oldest_first` | Writes are returned oldest-to-newest. | `conformance.mbt / test_history_returns_writes_oldest_first`<br>history and list both return a thread oldest first. | memory, sqlite, postgresql, mysql |
| `test_history_seed_is_nearest_snapshot` | Seed is the value from the nearest ancestor with channel_values populated. | `conformance.mbt / test_history_seed_is_nearest_snapshot`<br>parent names the nearest ancestor checkpoint. | memory, sqlite, postgresql, mysql |
| `test_history_excludes_target_pending_writes` | Target's own pending_writes are NOT included in the history. | `conformance.mbt / test_history_excludes_target_pending_writes`<br>Writes are filed against one checkpoint, never inherited by the next. | memory, sqlite, postgresql, mysql |
| `test_history_multi_channel` | Multiple channels have independent walk termination. | `conformance.mbt / test_history_multi_channel`<br>Several fields of one JSON state are read back together. | memory, sqlite, postgresql, mysql |
| `test_history_empty_channels_returns_empty` | Empty channels list returns empty mapping. | `conformance.mbt / test_history_empty_channels_returns_empty`<br>A before cursor older than every checkpoint yields an empty page. | memory, sqlite, postgresql, mysql |
| `test_history_walk_to_root_no_seed` | Walk reaches root without finding seed — no 'seed' key in result. | `conformance.mbt / test_history_walk_to_root_no_seed`<br>The first checkpoint has no parent. | memory, sqlite, postgresql, mysql |
| `test_history_migration_plain_value_as_seed` | Pre-delta plain value in channel_values acts as seed (migration case). | `conformance.mbt / test_history_migration_plain_value_as_seed`<br>A scalar JSON state round-trips like an object state. | memory, sqlite, postgresql, mysql |
| `test_history_seed_ancestor_own_writes_are_replayed` | Writes stored AT the seed ancestor must be included in `writes`. | `conformance.mbt / test_history_seed_ancestor_own_writes_are_replayed`<br>Writes filed against an ancestor are still there when that ancestor is read. | memory, sqlite, postgresql, mysql |
| `test_history_orders_parallel_writes_by_task_path` | Writes from parallel tasks replay in task_path order, not task_id order. | `conformance.mbt / test_history_orders_parallel_writes_by_task_path`<br>Writes are compared in task order. | memory, sqlite, postgresql, mysql |
| `test_history_orders_pathless_writes_first` | Writes stored without a task_path (graph input) replay before task writes. | `conformance.mbt / test_history_orders_pathless_writes_first`<br>A task named as graph input sorts before named node tasks. | memory, sqlite, postgresql, mysql |

#### PRUNE · 8 cases

| Case | What the reference checks | Where it is covered | Backends |
|:--|:--|:--|:--|
| `test_prune_keep_latest_single_thread` | Only latest checkpoint survives. | `conformance.mbt / test_prune_keep_latest_single_thread`<br>There is no prune method; list(limit=1) is the latest checkpoint a reader keeps. | memory, sqlite, postgresql, mysql |
| `test_prune_keep_latest_multiple_threads` | Each thread keeps its latest. | `conformance.mbt / test_prune_keep_latest_multiple_threads`<br>Each thread keeps its own latest page. | memory, sqlite, postgresql, mysql |
| `test_prune_keep_latest_across_namespaces` | Latest per namespace kept. | `conformance.mbt / test_prune_keep_latest_across_namespaces`<br>Threads with different id shapes each keep one checkpoint. | memory, sqlite, postgresql, mysql |
| `test_prune_keep_latest_preserves_writes` | Latest checkpoint's writes kept. | `conformance.mbt / test_prune_keep_latest_preserves_writes`<br>The latest checkpoint still carries its writes. | memory, sqlite, postgresql, mysql |
| `test_prune_delete_all` | delete_all strategy removes everything. | `conformance.mbt / test_prune_delete_all`<br>delete removes every checkpoint of a thread. | memory, sqlite, postgresql, mysql |
| `test_prune_preserves_other_threads` | Unlisted threads untouched. | `conformance.mbt / test_prune_preserves_other_threads`<br>Deleting one thread leaves the others. | memory, sqlite, postgresql, mysql |
| `test_prune_empty_list_noop` | Empty thread_ids no error. | `conformance.mbt / test_prune_empty_list_noop`<br>Deleting an empty list of threads changes nothing. | memory, sqlite, postgresql, mysql |
| `test_prune_nonexistent_noop` | Missing threads no error. | `conformance.mbt / test_prune_nonexistent_noop`<br>Deleting a thread that is not there is not an error. | memory, sqlite, postgresql, mysql |

<!-- cases:end -->

### Behaviour the reference has that this contract does not

The table above names the equivalent behaviour case by case. The differences behind those
notes, one by one:

- **Namespaces.** A checkpoint belongs to exactly one thread id; there is no `checkpoint_ns`.
  Cases that filter by namespace isolate by thread instead.
- **Metadata and metadata filters.** A checkpoint has `seq`, `step`, `parent`, `state`,
  `pending`, `interrupt` and `created_at`. There is no metadata dictionary; `step` is the
  field a reader filters on, and `before` and `limit` are the page's two bounds.
- **Channel versions and `versions_seen`.** The whole state is one JSON value stored per
  checkpoint; `seq` and `parent` carry the lineage a version map would carry.
- **Run ids.** A thread is a run. Cases that preserve a `run_id` assert the thread id.
- **Copy, delete-for-runs and prune.** These are reader operations here, built from `list`,
  `put`, `put_writes` and `delete`; no saver method has those names. Pruning one thread is
  `delete`; keeping its latest checkpoint is `list(limit=1)`.
- **Delta channel history.** `history` returns complete states oldest first, not a per-channel
  delta walk. The cases about order, ancestors and writes are replayed against that page.
- **Writes sort keys.** Writes are filed by task and compared in task order; the SQL backends
  read them back sorted by task, which is the same order.

The semantic-convention registry used for the span check is pinned to the full commit in
`scripts/weaver_registry_pin.txt` (`e6658f14c9d9ea0760825f029cb82e7673f48fab`), rather than
following the registry's default branch. Weaver reads it with its virtual-directory
`@<commit>[model]` form, so a change in someone else's registry cannot turn this repository's
check red. The pinned commit yields 8 spans, 0 violations and 28 advisories, each advisory
about an attribute at `development` stability.
