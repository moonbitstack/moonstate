// One node hands three tasks their own input; the three run in one superstep and
// their writes merge in task order.

///|
#derive(@json.ToJson, @json.FromJson)
struct Report {
  parts : Array[String]
  total : Int32
}

///|
pub extend Report with @json.ToJson::{to_json}

///|
pub extend Report with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
struct Part {
  parts : Array[String]?
  total : Int32?
}

///|
pub extend Part with @json.ToJson::{to_json}

///|
pub extend Part with @json.FromJson::{from_json}

///|
fn merge(state : Report, part : Part) -> Report {
  {
    parts: state.parts + part.parts.unwrap_or([]),
    total: state.total + part.total.unwrap_or(0),
  }
}

///|
async fn main {
  let graph = @moonstate.Builder::new(merge~, initial={ parts: [], total: 0, })
    .entry("fan")
    .node("fan", (state, _run) => {
      let steps : Array[@moonstate.Step[Report, Part]] = []
      for index = 0; index < 3; index = index + 1 {
        steps.push(@moonstate.Send("shard", { parts: [], total: index + 1, }))
      }
      let _ = state
      steps
    })
    .node("shard", (state, _run) => {
      [
        @moonstate.Write({
          parts: Some(["part " + state.total.to_string()]),
          total: Some(state.total),
        }),
      ]
    })
    .routed("shard")
    .compile("report") catch {
      refused =>
        abort("the graph does not compile: " + (refused : Error).to_string())
    }
  let out = graph.run({ parts: None, total: None, }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  println("parts = " + join(out.parts))
  println("total = " + out.total.to_string())
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
