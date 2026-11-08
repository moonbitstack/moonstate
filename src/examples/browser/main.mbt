// The site's engine: this library built to JavaScript, behind the handful of
// string functions a page needs. Everything the page shows — the phase it is on,
// the state it holds, the checkpoints behind it — comes from here, so the page
// cannot claim anything the engine did not do.

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
/// A merge that adds: the fan-out's three writes land on the same field, and a
/// replacing merge would keep only the last of them.
fn add_merge(state : Counter, patch : Patch) -> Counter {
  {
    n: state.n + patch.n.unwrap_or(0),
    log: state.log + patch.log.unwrap_or([]),
  }
}

///|
fn nothing() -> Patch {
  { n: None, log: None, }
}

///|
fn set(n : Int32) -> Patch {
  { n: Some(n), log: None, }
}

///|
fn note(label : String) -> Patch {
  { n: None, log: Some([label]), }
}

///|
/// The run the page is looking at. One page, one run: the exported functions are
/// steps of it.
priv struct Demo {
  scenario : String
  saver : @moonstate.MemorySaver
}

///|
let demo : Ref[Demo?] = Ref(None)

///|
/// The three graphs the page offers. Each is small enough to read on a ring and
/// shows a different part of the engine: a line, a question, a fan-out.
fn scenario_builder(scenario : String) -> @moonstate.Builder[Counter, Patch] {
  match scenario {
    "review" =>
      @moonstate.Builder::new(merge~, initial={ n: 0, log: [], })
      .entry("seed")
      .node("seed", (_state, _run) => [@moonstate.Write(set(1))])
      .node("ask", (_state, run) => {
        match run.answer() {
          Some(answer) => {
            let decided : Int32 = @json.from_json(answer)
            [@moonstate.Write({ n: Some(decided), log: Some(["answered"]), })]
          }
          None => [@moonstate.Interrupt({ "ask": "how many?" })]
        }
      })
      .node("settle", (_state, _run) => [@moonstate.Write(note("settled"))])
      .edge("seed", "ask")
      .edge("ask", "settle")
    "fanout" =>
      @moonstate.Builder::new(merge=add_merge, initial={ n: 0, log: [], })
      .entry("fan")
      .node("fan", (_state, _run) => {
        let steps : Array[@moonstate.Step[Counter, Patch]] = []
        for index = 0; index < 3; index = index + 1 {
          steps.push(
            @moonstate.Send("shard", {
              n: index,
              log: ["job" + index.to_string()],
            }),
          )
        }
        steps
      })
      .node("shard", (_state, _run) => {
        [@moonstate.Write({ n: Some(1), log: Some(["shard"]), })]
      })
      .routed("shard")
    _ =>
      @moonstate.Builder::new(merge~, initial={ n: 0, log: [], })
      .entry("seed")
      .node("seed", (_state, _run) => [@moonstate.Write(set(1))])
      .node("double", (state, _run) => [@moonstate.Write(set(state.n * 2))])
      .node("stamp", (state, _run) => {
        [@moonstate.Write({ n: Some(state.n + 10), log: Some(["stamp"]), })]
      })
      .edge("seed", "double")
      .edge("double", "stamp")
  }
}

///|
fn scenario_graph(
  scenario : String,
  saver : @moonstate.MemorySaver,
  limit : Int32,
) -> @moonstate.Graph[Counter, Patch] {
  scenario_builder(scenario).compile(scenario, saver~, limit~) catch {
    _ => abort("the demo graph does not compile")
  }
}

///|
fn failure(error : Error) -> String {
  let json : Json = {
    "status": "failed",
    "outcome": "failed",
    "reason": (error : Error).to_string(),
  }
  json.stringify()
}

///|
fn error_text(error : Error) -> String {
  match error {
    @moonstate.GraphError::NodeFailed(node~, message~) => node + ": " + message
    @moonstate.GraphError::Interrupted(..) => "waiting for an answer"
    @moonstate.GraphError::StepLimit(limit~) =>
      "the run took " + limit.to_string() + " supersteps"
    _ => (error : Error).to_string()
  }
}

///|
/// The run as the page reads it: how far it got, what it holds, what comes next,
/// and every checkpoint behind it. `outcome` is what the last call did — `done`,
/// `asking`, `failed`, or empty when nothing has run yet.
async fn report(running : Demo, outcome : String, reason : String?) -> String {
  let graph = scenario_graph(running.scenario, running.saver, 25)
  let snapshot = graph.state("demo")
  let history = graph.history("demo")
  let checkpoints : Array[Json] = []
  for one in history {
    checkpoints.push({
      "id": one.id,
      "step": Json(one.step),
      "next": Json::array(one.next.map(node => Json(node))),
      "state": @json.to_json(one.state),
      "interrupted": Json(one.interrupt is Some(_)),
    })
  }
  let out : Json = {
    "scenario": running.scenario,
    "limit": Json(graph.limit()),
    "phase": Json(
      match snapshot {
        Some(now) => now.step
        None => 0
      },
    ),
    "outcome": Json::string(outcome),
    "reason": match reason {
      Some(text) => Json::string(text)
      None => Json::null()
    },
    "state": match snapshot {
      Some(now) => @json.to_json(now.state)
      None => Json::null()
    },
    "next": match snapshot {
      Some(now) => Json::array(now.next.map(node => Json(node)))
      None => Json::array([])
    },
    "asking": match snapshot {
      Some(now) =>
        match now.interrupt {
          Some(value) => value
          None => Json::null()
        }
      None => Json::null()
    },
    "checkpoint": match snapshot {
      Some(now) => Json::string(now.id)
      None => Json::null()
    },
    "checkpoints": Json::array(checkpoints),
  }
  out.stringify()
}

///|
/// Run until the run stops for a reason of its own: the end of the graph, a
/// question, or a node that failed. Every one of those is durable — the
/// checkpoint is written before the superstep that stopped runs.
async fn run_to_stop(running : Demo) -> String {
  let graph = scenario_graph(running.scenario, running.saver, 25)
  let outcome = try {
    let _ = graph.run(nothing(), thread="demo")
    ("done", None)
  } catch {
    @moonstate.GraphError::Interrupted(..) => ("asking", None)
    error => ("failed", Some(error_text(error)))
  }
  let (label, reason) = outcome
  report(running, label, reason)
}

///|
/// Start a run, or start it over. The saver is fresh, so the ring goes back to the
/// first phase.
pub fn reset(scenario : String) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    let started = { scenario, saver: @moonstate.MemorySaver::new(), }
    demo.val = Some(started)
    report(started, "empty", None) catch {
      error => failure(error)
    }
  })
}

///|
/// Run the graph to its next stop.
///
/// A step limit is not how this is done: a checkpoint is written when a superstep
/// *starts*, so stopping the engine between supersteps would throw away the state
/// the last one produced. What the page gets instead is the truthful thing — every
/// stop the engine actually makes, with the checkpoints behind it — and the ring
/// is scrubbed over those records.
pub fn run() -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    match demo.val {
      None => "{\"status\":\"empty\"}"
      Some(running) => run_to_stop(running) catch { error => failure(error) }
    }
  })
}

///|
/// Answer the question a run stopped on, and run on from there.
pub fn answer(text : String) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    match demo.val {
      None => "{\"status\":\"empty\"}"
      Some(running) => {
        let given = @json.parse(text) catch { _ => Json(text) }
        let graph = scenario_graph(running.scenario, running.saver, 25)
        let outcome = try {
          let _ = graph.resume_with("demo", given)
          ("done", None)
        } catch {
          @moonstate.GraphError::Interrupted(..) => ("asking", None)
          error => ("failed", Some(error_text(error)))
        }
        let (label, reason) = outcome
        report(running, label, reason) catch {
          error => failure(error)
        }
      }
    }
  })
}

///|
/// Rewrite the state as if `node` had written it, then run what follows it. This
/// is the whole of time travel: the checkpoints of the abandoned attempt stay in
/// the thread, and the new ones are written on top of them.
pub fn rewrite(node : String) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    match demo.val {
      None => "{\"status\":\"empty\"}"
      Some(running) => {
        let graph = scenario_graph(running.scenario, running.saver, 25)
        let failure_text = try {
          graph.update(
            "demo",
            { n: Some(40), log: Some(["rewritten"]), },
            as_node=node,
          )
          None
        } catch {
          error => Some(error_text(error))
        }
        match failure_text {
          Some(reason) =>
            report(running, "failed", Some(reason)) catch {
              error => failure(error)
            }
          None => run_to_stop(running) catch { error => failure(error) }
        }
      }
    }
  })
}

///|
/// Every checkpoint and every write of the thread, as JSON — the whole of what a
/// `Saver` holds, which is what lets the page keep a run in the browser and pick
/// it up again after a reload.
pub fn dump() -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    match demo.val {
      None => "[]"
      Some(running) => {
        let records = running.saver.list("demo") catch { _ => [] }
        Json::array(records.map(one => @json.to_json(one))).stringify()
      }
    }
  })
}

///|
/// Put the records back and carry on: the run survives the page, because a
/// checkpoint is a record and a record is JSON.
pub fn restore(
  scenario : String,
  records : String,
) -> @js_async.Promise[String] {
  @js_async.Promise::from_async(async fn() {
    let saver = @moonstate.MemorySaver::new()
    let parsed = @json.parse(records) catch { _ => Json::array([]) }
    let stored : Array[@moonstate.Checkpoint] = @json.from_json(parsed) catch {
      _ => []
    }
    for one in stored {
      saver.put({ ..one, writes: None, }) catch {
        _ => ()
      }
      match one.writes {
        Some(writes) =>
          for write in writes {
            saver.put_writes("demo", one.id, write.task, write.values) catch {
              _ => ()
            }
          }
        None => ()
      }
    }
    let running = { scenario, saver, }
    demo.val = Some(running)
    report(running, "restored", None) catch {
      error => failure(error)
    }
  })
}
