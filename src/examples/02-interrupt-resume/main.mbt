// A run that stops to ask a question, then continues from where it stopped.
// The saver is the only thing that makes the pause survive the call.

///|
#derive(@json.ToJson, @json.FromJson)
struct Note {
  text : String
  done : Bool
}

///|
pub extend Note with @json.ToJson::{to_json}

///|
pub extend Note with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
struct Change {
  text : String?
  done : Bool?
}

///|
pub extend Change with @json.ToJson::{to_json}

///|
pub extend Change with @json.FromJson::{from_json}

///|
fn merge(state : Note, change : Change) -> Note {
  {
    text: change.text.unwrap_or(state.text),
    done: change.done.unwrap_or(state.done),
  }
}

///|
async fn main {
  let saver = @moonstate.MemorySaver::new()
  let graph = @moonstate.Builder::new(merge~, initial={ text: "", done: false, })
    .entry("draft")
    .node("draft", (_state, _run) => {
      [@moonstate.Write({ text: Some("half written"), done: None, })]
    })
    .node("approve", (_state, run) => {
      match run.answer() {
        Some(answer) => {
          let approved : Bool = @json.from_json(answer) catch { _ => false }
          [@moonstate.Write({ text: None, done: Some(approved), })]
        }
        None => [@moonstate.Interrupt({ "ask": "approve the draft?" })]
      }
    })
    .node("publish", (_state, _run) => {
      [@moonstate.Write({ text: None, done: Some(true), })]
    })
    .edge("draft", "approve")
    .edge("approve", "publish")
    .compile("review", saver~) catch {
      refused =>
        abort("the graph does not compile: " + (refused : Error).to_string())
    }
  let paused = try {
    graph.run({ text: None, done: None, }, thread="review") |> ignore
    false
  } catch {
    @moonstate.Interrupted(thread~, value~) => {
      println("thread " + thread + " asks: " + value.stringify())
      true
    }
    error => abort("the run failed: " + (error : Error).to_string())
  }
  if !paused {
    abort("the run was expected to stop at the question")
  }
  let out = graph.resume_with("review", Json(true)) catch {
    error => abort("the resume failed: " + (error : Error).to_string())
  }
  println("text = " + out.text)
  println("done = " + out.done.to_string())
}
