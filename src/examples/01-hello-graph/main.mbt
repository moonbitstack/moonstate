// A first graph: three nodes in a line, streamed as they run. The state is a
// counter and a log; each node writes only the field it touches.

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
/// The state of nothing done yet, and what a node writes back.
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
async fn main {
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, log: [], })
    .entry("seed")
    .node("seed", (_state, _run) => {
      [@moonstate.Write({ n: Some(1), log: Some(["seed"]), })]
    })
    .node("double", (state, _run) => {
      [@moonstate.Write({ n: Some(state.n * 2), log: Some(["double"]), })]
    })
    .node("label", (_state, _run) => {
      [@moonstate.Write({ n: None, log: Some(["label"]), })]
    })
    .edge("seed", "double")
    .edge("double", "label")
    .compile("hello") catch {
      refused =>
        abort("the graph does not compile: " + (refused : Error).to_string())
    }
  let out = graph.run({ n: None, log: None, }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  println("n = " + out.n.to_string())
  println("log = " + join(out.log))
}

///|
fn merge(state : Counter, patch : Patch) -> Counter {
  { n: patch.n.unwrap_or(state.n), log: state.log + patch.log.unwrap_or([]), }
}

///|
/// A list as one line, because the debug rendering of a list is a tree.
fn join(items : Array[String]) -> String {
  let text = StringBuilder()
  for index = 0; index < items.length(); index = index + 1 {
    if index > 0 {
      text.write_string(", ")
    }
    text.write_string(items[index])
  }
  text.to_string()
}
