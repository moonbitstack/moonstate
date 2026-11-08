// The checkpoint scenarios, written once and run against every backend. Each
// scenario appends what it observed to one transcript, so two backends that agree
// produce byte-identical transcripts.

///|
#derive(@json.ToJson, @json.FromJson)
struct Counter {
  n : Int32
  log : Array[String]
}

///|
pub extend Counter with @json.ToJson::{to_json}

///|
pub extend Counter with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
struct Patch {
  n : Int32?
  log : Array[String]?
}

///|
pub extend Patch with @json.ToJson::{to_json}

///|
pub extend Patch with @json.FromJson::{from_json}

///|
fn merge(state : Counter, patch : Patch) -> Counter {
  { n: patch.n.unwrap_or(state.n), log: state.log + patch.log.unwrap_or([]), }
}

///|
fn state_text(state : Counter) -> String {
  "n=" + state.n.to_string() + " log=" + state.log.join(",")
}

///|
fn empty() -> Patch {
  { n: None, log: None, }
}

///|
fn note(out : Array[String], line : String) -> Unit {
  out.push(line)
}

///|
/// One run's error as a line, so that a backend which fails differently shows up
/// as a differing transcript rather than as a crash.
fn failure(error : Error) -> String {
  match error {
    @moonstate.GraphError::Interrupted(value~, ..) =>
      "interrupted " + value.stringify()
    @moonstate.GraphError::NodeFailed(node~, message~) =>
      "failed " + node + ": " + message
    @moonstate.GraphError::MissingThread(thread~) => "missing thread " + thread
    @moonstate.GraphError::NotInterrupted(thread~) =>
      "not interrupted " + thread
    @moonstate.GraphError::StepLimit(limit~) =>
      "step limit " + limit.to_string()
    _ => "other " + error.to_string()
  }
}

///|
/// A graph that asks a question in its second superstep and finishes once the
/// answer arrives.
fn[S : @moonstate.Saver, T : @moonstate.Store] gate_graph(
  saver : S,
  store : T,
) -> @moonstate.Graph[Counter, Patch] {
  let builder = @moonstate.Builder::new(merge~, initial={ n: 0, log: [], })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]), })]
    })
    .node("gate", (_state, run) => {
      match run.answer() {
        Some(answer) => {
          let n : Int32 = @json.from_json(answer)
          [@moonstate.Write({ n: Some(n), log: Some(["gate"]), })]
        }
        None => [@moonstate.Interrupt({ "ask": "approve?" })]
      }
    })
    .edge("seed", "gate")
  builder.compile("gate", saver~, store~) catch {
    error =>
      abort("the gate graph does not compile: " + (error : Error).to_string())
  }
}

///|
/// Run to the end or to a stop, and report which happened.
async fn[T : @json.ToJson + @json.FromJson, U : @json.ToJson + @json.FromJson] first_run(
  graph : @moonstate.Graph[T, U],
  input : U,
  thread : String,
) -> String {
  try {
    let _ = graph.run(input, thread~)
    "finished"
  } catch {
    error => failure(error)
  }
}

///|
/// Scenario one: a run stops at a question, the checkpoint carries it, and the
/// answer continues the thread where it stopped.
async fn[S : @moonstate.Saver, T : @moonstate.Store] asked_and_answered(
  saver : S,
  store : T,
  out : Array[String],
) -> Unit {
  let thread = "one-asked"
  let graph = gate_graph(saver, store)
  note(out, "ask: " + first_run(graph, empty(), thread))
  let snapshot = graph.state(thread).unwrap()
  note(out, "waiting on: " + snapshot.next.join(","))
  note(out, "interrupt: " + snapshot.interrupt.unwrap().stringify())
  note(out, "steps so far: " + snapshot.step.to_string())
  let answered = graph.resume_with(thread, Json(7))
  note(out, "answer: " + state_text(answered))
  let settled = graph.state(thread).unwrap()
  note(out, "done, waiting on " + settled.next.length().to_string() + " nodes")
  saver.delete(thread)
}

///|
/// Scenario two: two tasks in one superstep, one of them fails. What the other
/// filed has to survive the failure, so the retry does not run it twice.
async fn[S : @moonstate.Saver, T : @moonstate.Store] filed_writes_survive(
  saver : S,
  store : T,
  out : Array[String],
) -> Unit {
  let thread = "two-filed"
  let good_runs = Ref(0)
  let bad_runs = Ref(0)
  let builder = @moonstate.Builder::new(merge~, initial={ n: 0, log: [], })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]), })]
    })
    .branch("seed", _state => ["good", "bad"])
    .node("good", (_state, _run) => {
      good_runs.val = good_runs.val + 1
      [@moonstate.Write({ n: None, log: Some(["good"]), })]
    })
    .node("bad", (_state, _run) => {
      bad_runs.val = bad_runs.val + 1
      if bad_runs.val == 1 {
        raise Failure::Failure("the first attempt fails")
      }
      [@moonstate.Write({ n: Some(100), log: Some(["bad"]), })]
    })
    .routed("good")
    .routed("bad")
  let graph = builder.compile("fan", saver~, store~) catch {
    error =>
      abort("the fan graph does not compile: " + (error : Error).to_string())
  }
  note(out, "crash: " + first_run(graph, empty(), thread))
  note(
    out,
    "good ran " +
    good_runs.val.to_string() +
    ", bad ran " +
    bad_runs.val.to_string(),
  )
  let second = try {
    let done = graph.run(empty(), thread~)
    "finished " + state_text(done)
  } catch {
    error => failure(error)
  }
  note(out, "restart: " + second)
  note(
    out,
    "good ran " +
    good_runs.val.to_string() +
    ", bad ran " +
    bad_runs.val.to_string(),
  )
  saver.delete(thread)
}

///|
/// Scenario three: the thread's checkpoints, all of them, a page of the newest
/// two, and the page below a given checkpoint.
async fn[S : @moonstate.Saver, T : @moonstate.Store] history_pages(
  saver : S,
  store : T,
  out : Array[String],
) -> Unit {
  let thread = "three-history"
  let graph = gate_graph(saver, store)
  let _ = first_run(graph, empty(), thread)
  let _ = graph.resume_with(thread, Json(3))
  let history = graph.history(thread)
  note(out, "history: " + history.length().to_string())
  for snapshot in history {
    note(
      out,
      "  " +
      snapshot.id +
      " step=" +
      snapshot.step.to_string() +
      " " +
      state_text(snapshot.state) +
      " next=" +
      snapshot.next.join(","),
    )
  }
  let page = saver.list(thread, limit=2)
  note(out, "newest two: " + page.map(checkpoint => checkpoint.id).join(","))
  let older = saver.list(thread, limit=1, before="cp-000002")
  note(
    out,
    "before cp-000002: " + older.map(checkpoint => checkpoint.id).join(","),
  )
  saver.delete(thread)
}

///|
/// Scenario four: a finished thread is taken back to an earlier decision and run
/// forward again from there.
async fn[S : @moonstate.Saver, T : @moonstate.Store] time_travel(
  saver : S,
  store : T,
  out : Array[String],
) -> Unit {
  let thread = "four-rewrite"
  // A line rather than a gate: the rewrite re-runs the tail without stopping to
  // ask anything, which is what makes the state it produces comparable.
  let builder = @moonstate.Builder::new(merge~, initial={ n: 0, log: [], })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]), })]
    })
    .node("double", (state, _run) => {
      [@moonstate.Write({ n: Some(state.n * 2), log: Some(["double"]), })]
    })
    .edge("seed", "double")
  let graph = builder.compile("line", saver~, store~) catch {
    error =>
      abort("the line graph does not compile: " + (error : Error).to_string())
  }
  note(out, "line: " + state_text(graph.run(empty(), thread~)))
  graph.update(
    thread,
    { n: Some(10), log: Some(["rewritten"]), },
    as_node="seed",
  )
  let after = graph.run(empty(), thread~)
  note(out, "after rewrite: " + state_text(after))
  saver.delete(thread)
}

///|
/// Scenario five: a deleted thread is gone, and asking for it says so.
async fn[S : @moonstate.Saver, T : @moonstate.Store] deleted_thread(
  saver : S,
  store : T,
  out : Array[String],
) -> Unit {
  let thread = "five-deleted"
  let graph = gate_graph(saver, store)
  let _ = first_run(graph, empty(), thread)
  saver.delete(thread)
  let left = match graph.state(thread) {
    Some(_) => "still there"
    None => "gone"
  }
  note(out, "state after delete: " + left)
  let resumed = try {
    let _ = graph.resume_with(thread, Json(1))
    "resumed"
  } catch {
    error => failure(error)
  }
  note(out, "resume after delete: " + resumed)
}

///|
/// Scenario six: long-term memory — whole namespaces, everything below one, and
/// the text and field narrowings.
async fn[T : @moonstate.Store] memory_across_threads(
  store : T,
  out : Array[String],
) -> Unit {
  store.put(["mem"], "global", { "text": "shared", "kind": "note" })
  store.put(["mem", "facts"], "oslo", { "text": "capital", "kind": "fact" })
  store.put(["mem", "facts"], "bern", { "text": "capital too", "kind": "fact" })
  store.put(["other"], "elsewhere", { "text": "capital", "kind": "note" })
  note(out, "exact: " + describe(store.get(["mem", "facts"], "oslo")))
  note(out, "under mem: " + describe_all(store.search(["mem"], limit=10)))
  note(
    out,
    "text capital: " +
    describe_all(store.search(["mem"], query="capital", limit=10)),
  )
  note(
    out,
    "kind fact: " +
    describe_all(
      store.search(["mem"], filter={ "kind": Json("fact") }, limit=10),
    ),
  )
  // Which row a limit keeps is the backend's idea of "newest", so only the count
  // is comparable across backends here.
  note(out, "limit one: " + store.search(["mem"], limit=1).length().to_string())
  store.delete(["mem", "facts"], "oslo")
  note(out, "after delete: " + describe(store.get(["mem", "facts"], "oslo")))
}

///|
fn describe(item : @moonstate.Item?) -> String {
  match item {
    Some(item) => item.space.join("/") + ":" + item.key
    None => "nothing"
  }
}

///|
fn describe_all(items : Array[@moonstate.Item]) -> String {
  // Sorted: an in-memory store returns its own iteration order, so the set is what
  // two backends can be held to, not the order.
  let names = items.map(item => item.space.join("/") + ":" + item.key)
  names.sort()
  names.join(" ")
}

///|
/// Every scenario, in order, against one saver and one store.
pub async fn[S : @moonstate.Saver, T : @moonstate.Store] suite(
  saver : S,
  store : T,
) -> Array[String] {
  let out : Array[String] = []
  asked_and_answered(saver, store, out)
  filed_writes_survive(saver, store, out)
  history_pages(saver, store, out)
  time_travel(saver, store, out)
  deleted_thread(saver, store, out)
  memory_across_threads(store, out)
  out
}
