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
  n : Int32
  log : Array[String]
}

pub extend Counter with @json.ToJson::{to_json}

pub extend Counter with @json.FromJson::{from_json}

#derive(@json.ToJson, @json.FromJson)
struct Patch {
  n : Int32?
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
async test "the graph runs" {
  let hello = @moonstate.Builder::new(merge=merge, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]) })]
    })
    .node("double", (state, _run) => {
      [@moonstate.Write({ n: Some(state.n * 2), log: None })]
    })
    .edge("seed", "double")
    .compile("hello") catch { error => abort((error : Error).to_string()) }
  let out = hello.run({ n: None, log: None }) catch { error => abort((error : Error).to_string()) }
  assert_eq(out.n, 2)
}
```

## Durable runs

Compile with a `Saver`, pass a `thread` to `run`, and a second `run` on the same thread
continues from the last checkpoint instead of starting over.

```moonbit
async test "a thread outlives the call that started it" {
  let saver = @moonstate.MemorySaver::new()
  let durable = @moonstate.Builder::new(merge=merge, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(1), log: None })])
    .compile("durable", saver=saver) catch { error => abort((error : Error).to_string()) }
  let _ = durable.run({ n: None, log: None }, thread="job") catch {
    error => abort((error : Error).to_string())
  }
  let again = durable.run({ n: None, log: None }, thread="job") catch {
    error => abort((error : Error).to_string())
  }
  assert_eq(again.n, 1)
  let history = durable.history("job") catch { error => abort((error : Error).to_string()) }
  assert_eq(history.length(), 4)
}
```

The same handles also cover the rest of a durable workflow:

- `graph.state("job")` — the thread as it stands, and `graph.history("job")` — every
  checkpoint it took, oldest first, each naming the one it was written on top of.
- `graph.update("job", patch, as_node="double")` — rewrite the latest state as if that node
  had written it, then run what follows it.
- `graph.resume_with("job", answer)` — continue a thread whose node returned `Interrupt`.

`MemorySaver` keeps checkpoints in the process. `moonbitstack/moonstate/sql` puts them in
SQLite, PostgreSQL or MySQL: `@sql.saver(connection)` and `@sql.store(connection)`, with
`setup()` to create the tables. One connection carries one saver and one store; a blocking
driver goes in through `@sql.blocking(connection)`.

## Interrupts

The node that asks returns `Interrupt`; the run raises `GraphError::Interrupted`; the answer
arrives through `run.answer()` when the thread is resumed, and the node runs again.

```moonbit
async test "the answer continues the thread" {
  let approval = @moonstate.Builder::new(merge=merge, initial={ n: 0, log: [] })
    .entry("approve")
    .node("approve", (_state, run) => match run.answer() {
      Some(answer) => {
        let decided : Int32 = @json.from_json(answer)
        [@moonstate.Write({ n: Some(decided), log: None })]
      }
      None => [@moonstate.Interrupt({ "ask": "approve?" })]
    })
    .compile("approval", saver=@moonstate.MemorySaver::new()) catch {
      error => abort((error : Error).to_string())
    }
  let asked = try {
    let _ = approval.run({ n: None, log: None }, thread="review")
    false
  } catch {
    @moonstate.GraphError::Interrupted(..) => true
    _ => abort("the run failed for another reason")
  }
  assert_true(asked)
  let out = approval.resume_with("review", Json(7)) catch {
    error => abort((error : Error).to_string())
  }
  assert_eq(out.n, 7)
}
```

## Fan-out

`Send` queues a node once per input; the tasks run in one superstep and merge in the order
they were queued. A node entered only by `Send` has to be declared with `routed`, or
`compile` refuses the graph as unreachable.

```moonbit
#derive(@json.ToJson, @json.FromJson)
struct Score {
  hits : Int32
}

pub extend Score with @json.ToJson::{to_json}

pub extend Score with @json.FromJson::{from_json}

#derive(@json.ToJson, @json.FromJson)
struct Hit {
  hits : Int32
}

pub extend Hit with @json.ToJson::{to_json}

pub extend Hit with @json.FromJson::{from_json}

fn score_merge(state : Score, hit : Hit) -> Score {
  { hits: state.hits + hit.hits }
}

async test "four sends are one superstep" {
  let fan = @moonstate.Builder::new(merge=score_merge, initial={ hits: 0 })
    .entry("fan")
    .node("fan", (_state, _run) => {
      let steps : Array[@moonstate.Step[Score, Hit]] = []
      for shard = 0; shard < 4; shard = shard + 1 {
        steps.push(@moonstate.Send("score", { hits: shard }))
      }
      steps
    })
    .node("score", (state, _run) => [@moonstate.Write({ hits: state.hits + 1 })])
    .routed("score")
    .compile("fan") catch { error => abort((error : Error).to_string()) }
  let out = fan.run({ hits: 0 }) catch { error => abort((error : Error).to_string()) }
  assert_eq(out.hits, 10)
}
```

## Traces

`moonbitstack/moonstate/otel` hands the engine an executor that opens a span per superstep
and a child span per node, named with the OpenTelemetry GenAI semantic conventions:
`gen_ai.operation.name` is `invoke_agent` on a superstep and `execute_tool` on a node,
`gen_ai.agent.name` is the graph, `gen_ai.tool.name` is the node, and
`gen_ai.conversation.id` is the thread.

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

async test "a traced run has a span per node" {
  let spans = @trace.Recorder::new()
  let tracer = @trace.Tracer::new(
    rand=random_bytes,
    sink=spans,
    sampler=@trace.parent_based(root=@trace.always),
  )
  let executor = @otel.traced(@moonstate.inline, tracer~, now=clock)
  let graph = @moonstate.Builder::new(merge=merge, initial={ n: 0, log: [] })
    .entry("seed")
    .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(1), log: None })])
    .compile("traced", executor=executor)
  let _ = graph.run({ n: None, log: None }) catch { error => abort((error : Error).to_string()) }
  assert_eq(spans.spans().map(span => span.name), ["seed", "superstep 0"])
}
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
- `run` on a finished thread starts a new turn rather than returning the old result: the
  checkpoints of the earlier turn stay in the thread's history.
