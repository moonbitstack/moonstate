// An executor that ships each task to another process.
//
// The node bodies in this file never run in the parent: the executor hands the
// task's node name and input, as JSON, to a child of the same binary, and reads
// the steps it wrote back as JSON. That is the whole `Executor` contract — the
// engine never learns where a task ran.

///|
#derive(@json.ToJson, @json.FromJson)
struct Counter {
  n : Int32
}

///|
pub extend Counter with @json.ToJson::{to_json}

///|
pub extend Counter with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
struct Patch {
  n : Int32?
}

///|
pub extend Patch with @json.ToJson::{to_json}

///|
pub extend Patch with @json.FromJson::{from_json}

///|
fn merge(state : Counter, patch : Patch) -> Counter {
  { n: patch.n.unwrap_or(state.n), }
}

///|
/// The node registry the child resolves a task against, by name.
fn steps_for(node : String, state : Counter) -> Array[Json] {
  let steps : Array[@moonstate.Step[Counter, Patch]] = match node {
    "double" => [@moonstate.Write({ n: Some(state.n * 2), })]
    "increment" => [@moonstate.Write({ n: Some(state.n + 1), })]
    _ => abort("no node named '" + node + "' in the child")
  }
  steps.map(step => step.encode())
}

///|
struct Sidecar {
  exe : String
}

///|
pub impl @moonstate.Executor for Sidecar with fn each(self, works) -> Array[
  @moonstate.Done,
] raise {
  let done : Array[@moonstate.Done] = []
  for work in works {
    let input = (work.input)().stringify()
    let (code, out, err) = @process.collect_output(self.exe, [
      "child",
      work.node,
      input,
    ])
    if code != 0 {
      done.push(@moonstate.Done::{
        values: None,
        error: Some(
          "the child exited with " + code.to_string() + ": " + err.text(),
        ),
      })
      continue
    }
    let answer = @json.parse(out.text()) catch {
      error =>
        raise Failure::Failure(
          "the child answered with a bad line: " + (error : Error).to_string(),
        )
    }
    match answer {
      Array(values) =>
        done.push(@moonstate.Done::{ values: Some(values), error: None, })
      _ =>
        done.push(@moonstate.Done::{
          values: None,
          error: Some("the child did not answer with a list of steps"),
        })
    }
  }
  done
}

///|
pub extend Sidecar with @moonstate.Executor::{each}

///|
async fn main {
  let args = @env.args()
  if args.length() > 1 && args[1] == "child" {
    // The child side: one node, one input, one answer.
    let node = args[2]
    let input : Counter = @json.from_json(@json.parse(args[3])) catch {
      error => abort("bad input: " + (error : Error).to_string())
    }
    println(@json.to_json(steps_for(node, input)).stringify())
    return
  }
  let sidecar = { exe: args[0], }
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, })
    .entry("double")
    .node("double", (_state, _run) => {
      abort("this node runs in the child process")
    })
    .node("increment", (_state, _run) => {
      abort("this node runs in the child process")
    })
    .edge("double", "increment")
    .compile("sidecar", executor=sidecar) catch {
      refused =>
        abort("the graph does not compile: " + (refused : Error).to_string())
    }
  let out = graph.run({ n: Some(20), }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  println("n = " + out.n.to_string())
}
