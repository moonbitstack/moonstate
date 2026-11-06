///|
/// A saver that wraps another one and fails on the `fail_at`-th `put`. That is
/// what a process dying between two supersteps looks like from the outside.
struct FlakySaver {
  inner : &@moonstate.Saver
  fail_at : Int32
  puts : Ref[Int32]
  wrote : Ref[Int32]
}

///|
pub impl @moonstate.Saver for FlakySaver with fn get(self, thread, id?) -> @moonstate.Checkpoint? raise {
  self.inner.get(thread, id?)
}

///|
pub impl @moonstate.Saver for FlakySaver with fn put(self, checkpoint) -> Unit raise {
  self.puts.val = self.puts.val + 1
  if self.puts.val == self.fail_at {
    raise Failure::Failure("the process went away")
  }
  self.inner.put(checkpoint)
}

///|
pub impl @moonstate.Saver for FlakySaver with fn put_writes(
  self,
  thread,
  id,
  task,
  values,
) -> Unit raise {
  self.wrote.val = self.wrote.val + 1
  self.inner.put_writes(thread, id, task, values)
}

///|
pub impl @moonstate.Saver for FlakySaver with fn list(
  self,
  thread,
  limit?,
  before?,
) -> Array[@moonstate.Checkpoint] raise {
  self.inner.list(thread, limit?, before?)
}

///|
pub impl @moonstate.Saver for FlakySaver with fn delete(self, thread) -> Unit raise {
  self.inner.delete(thread)
}

///|
pub extend FlakySaver with @moonstate.Saver::{
  get,
  put,
  put_writes,
  list,
  delete,
}

///|
/// A three-step graph: `a`, then `b`, then `c`, each logging its own name.
fn three_step_with(
  saver : &@moonstate.Saver,
) -> @moonstate.Graph[Counter, Patch] {
  counter_builder()
  .entry("a")
  .node("a", (_state, _run) => [@moonstate.Write(add("a"))])
  .node("b", (_state, _run) => [@moonstate.Write(add("b"))])
  .node("c", (_state, _run) => [@moonstate.Write(add("c"))])
  .edge("a", "b")
  .edge("b", "c")
  .compile("three", saver~) catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
}

///|
/// A graph that stops at `gate` until it is resumed with an answer, then finishes.
fn gated() -> @moonstate.Graph[Counter, Patch] {
  counter_builder()
  .entry("before")
  .node("before", (_state, _run) => [@moonstate.Write(add("before"))])
  .node("gate", (_state, run) => {
    match run.answer() {
      Some(answer) => {
        let n : Int32 = @json.from_json(answer) catch {
          error => abort("answer: " + (error : Error).to_string())
        }
        [@moonstate.Write(count(n, "gate"))]
      }
      None => [@moonstate.Interrupt(Json(7))]
    }
  })
  .node("after", (_state, _run) => [@moonstate.Write(add("after"))])
  .edge("before", "gate")
  .edge("gate", "after")
  .compile("gated", saver=@moonstate.MemorySaver::new()) catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
}

///|
/// Run the gated graph until it stops at its interrupt, failing the test for any
/// other outcome.
async fn run_blocked(
  graph : @moonstate.Graph[Counter, Patch],
  thread : String,
) -> Unit {
  let _ = try {
    graph.run(seed(0), thread~) |> ignore
    true
  } catch {
    @moonstate.Interrupted(..) => false
    error => fail("run: " + (error : Error).to_string())
  }
}

///|
async test "a checkpoint is written before every superstep" {
  let saver = @moonstate.MemorySaver::new()
  let graph = three_step_with(saver)
  let out = graph.run(seed(0), thread="t") catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["a", "b", "c"])
  let history = graph.history("t") catch {
    error => fail("history: " + (error : Error).to_string())
  }
  // One checkpoint per superstep, plus the one the finished run leaves behind.
  assert_eq(history.length(), 4)
  assert_eq(history[0].state.log, [])
  assert_eq(history[1].state.log, ["a"])
  assert_eq(history[2].state.log, ["a", "b"])
  assert_eq(history[3].state.log, ["a", "b", "c"])
  assert_eq(history[0].next, ["a"])
  assert_eq(history[2].next, ["c"])
  assert_eq(history[3].next, [])
}

///|
async test "the latest checkpoint is the finished state" {
  let saver = @moonstate.MemorySaver::new()
  let graph = three_step_with(saver)
  let _ = graph.run(seed(0), thread="t") catch {
    error => fail("run: " + (error : Error).to_string())
  }
  let state = graph.state("t") catch {
    error => fail("state: " + (error : Error).to_string())
  }
  let latest = state.unwrap()
  assert_eq(latest.state.log, ["a", "b", "c"])
  assert_eq(latest.next, [])
  assert_eq(latest.interrupt, None)
}

///|
async test "an interrupt stops the run with the node still queued" {
  let graph = gated()
  let message = try {
    graph.run(seed(0), thread="t") |> ignore
    "no failure"
  } catch {
    @moonstate.Interrupted(thread~, value~) => thread + " " + value.stringify()
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "t 7")
  let state = (graph.state("t") catch {
    error => fail("state: " + (error : Error).to_string())
  }).unwrap()
  assert_eq(state.next, ["gate"])
  assert_eq(state.state.log, ["before"])
  assert_eq(state.interrupt, Some(Json(7)))
}

///|
async test "resume hands the answer to the node that waited" {
  let graph = gated()
  run_blocked(graph, "t")
  let out = graph.resume_with("t", Json(42)) catch {
    error => fail("resume: " + (error : Error).to_string())
  }
  assert_eq(out.n, 42)
  assert_eq(out.log, ["before", "gate", "after"])
}

///|
async test "resuming a thread that finished reports nothing to continue" {
  let graph = gated()
  run_blocked(graph, "t")
  let _ = graph.resume_with("t", Json(1)) catch {
    error => fail("resume: " + (error : Error).to_string())
  }
  let message = try {
    graph.resume_with("t", Json(2)) |> ignore
    "no failure"
  } catch {
    @moonstate.NotInterrupted(..) => "not interrupted"
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "not interrupted")
}

///|
async test "history keeps the checkpoints of the interrupted attempt too" {
  let graph = gated()
  run_blocked(graph, "t")
  let _ = graph.resume_with("t", Json(9)) catch {
    error => fail("resume: " + (error : Error).to_string())
  }
  let history = graph.history("t") catch {
    error => fail("history: " + (error : Error).to_string())
  }
  // before, gate (interrupted and then resumed), after, and the finished state:
  // one checkpoint per superstep, and the one for the gate carries the question.
  assert_eq(history.length(), 4)
  assert_eq(history[0].next, ["before"])
  assert_eq(history[1].next, ["gate"])
  assert_eq(history[1].interrupt, Some(Json(7)))
  assert_eq(history[3].next, [])
}

///|
async test "update rewrites the thread and the next run continues from there" {
  let saver = @moonstate.MemorySaver::new()
  let graph = three_step_with(saver)
  let _ = graph.run(seed(0), thread="t") catch {
    error => fail("run: " + (error : Error).to_string())
  }
  graph.update("t", count(100, "rewound"), as_node="b") catch {
    error => fail("update: " + (error : Error).to_string())
  }
  let out = graph.run(seed(0), thread="t") catch {
    error => fail("second run: " + (error : Error).to_string())
  }
  assert_eq(out.n, 100)
  // `as_node` says the write came from `b`, so only what follows `b` runs again.
  assert_eq(out.log, ["a", "b", "c", "rewound", "c"])
}

///|
async test "a run that dies between supersteps resumes at the last checkpoint" {
  let memory = @moonstate.MemorySaver::new()
  let flaky = { inner: memory, fail_at: 3, puts: Ref(0), wrote: Ref(0), }
  let graph = three_step_with(flaky)
  let message = try {
    graph.run(seed(0), thread="t") |> ignore
    "no failure"
  } catch {
    @moonstate.Backend(..) => "died"
    error => "other: " + (error : Error).to_string()
  }
  assert_eq(message, "died")
  // The run is picked up by the same graph: two supersteps are already durable.
  let out = graph.run(seed(0), thread="t") catch {
    error => fail("retry: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["a", "b", "c"])
}

///|
async test "delete drops a thread's checkpoints" {
  let saver = @moonstate.MemorySaver::new()
  let graph = three_step_with(saver)
  let _ = graph.run(seed(0), thread="t") catch {
    error => fail("run: " + (error : Error).to_string())
  }
  saver.delete("t") catch {
    error => fail("delete: " + (error : Error).to_string())
  }
  let history = graph.history("t") catch {
    error => fail("history: " + (error : Error).to_string())
  }
  assert_eq(history.length(), 0)
}

///|
/// A superstep whose tasks do not all survive: the one that finished is not run
/// again when the thread is picked up, because its write was filed first.
async test "a finished task is not run twice when its neighbour fails" {
  let saver = @moonstate.MemorySaver::new()
  let steady_runs = Ref(0)
  let wobbly_runs = Ref(0)
  let graph = counter_builder()
    .entry("start")
    .node("start", (_state, _run) => [])
    .node("steady", (_state, _run) => {
      steady_runs.val = steady_runs.val + 1
      [@moonstate.Write(add("steady"))]
    })
    .node("wobbly", (_state, _run) => {
      wobbly_runs.val = wobbly_runs.val + 1
      if wobbly_runs.val == 1 {
        raise Failure::Failure("the first attempt fails")
      }
      [@moonstate.Write(add("wobbly"))]
    })
    .edge("start", "steady")
    .edge("start", "wobbly")
    .compile("mixed", saver~) catch {
      refused => abort("refused: " + (refused : Error).to_string())
    }
  let failed = try {
    graph.run(seed(0), thread="t") |> ignore
    true
  } catch {
    @moonstate.NodeFailed(..) => false
    error => abort("run: " + (error : Error).to_string())
  }
  assert_eq(failed, false)
  let out = graph.run(seed(0), thread="t") catch {
    error => fail("second run: " + (error : Error).to_string())
  }
  assert_eq(out.log, ["steady", "wobbly"])
  assert_eq(steady_runs.val, 1)
  assert_eq(wobbly_runs.val, 2)
}
