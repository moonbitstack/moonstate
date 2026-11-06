///|
/// An executor that records the batches it is handed and then runs them here.
struct Recorder {
  batches : Array[Array[String]]
  attempts : Array[Int32]
}

///|
pub impl @moonstate.Executor for Recorder with fn each(self, works) -> Array[
  @moonstate.Done,
] raise {
  let names = []
  for work in works {
    names.push(work.node)
    self.attempts.push(work.attempt)
  }
  self.batches.push(names)
  let done : Array[@moonstate.Done] = []
  for work in works {
    let outcome = Ok((work.run)()) catch { error => Err(error) }
    match outcome {
      Ok(values) =>
        done.push(@moonstate.Done::{ values: Some(values), error: None, })
      Err(error) =>
        done.push(@moonstate.Done::{
          values: None,
          error: Some(error.to_string()),
        })
    }
  }
  done
}

///|
pub extend Recorder with @moonstate.Executor::{each}

///|
/// An executor that never touches the node: it answers from the JSON the task
/// carries, the way a worker in another process answers from a name it looked up
/// on its side. If the engine needed anything beyond JSON, this could not work.
struct Remote {}

///|
pub impl @moonstate.Executor for Remote with fn each(_self, works) -> Array[
  @moonstate.Done,
] raise {
  let done : Array[@moonstate.Done] = []
  for work in works {
    let state : Counter = @json.from_json((work.input)()) catch {
      error => raise Failure::Failure(error.to_string())
    }
    done.push(@moonstate.Done::{
      values: Some([
        { "kind": "write", "value": { "n": state.n + 100, "log": ["remote"] } },
      ]),
      error: None,
    })
  }
  done
}

///|
pub extend Remote with @moonstate.Executor::{each}

///|
async test "the executor is handed one batch per superstep, in order" {
  let recorder = { batches: [], attempts: [], }
  let graph = counter_builder()
    .entry("start")
    .node("start", (_state, _run) => [])
    .node("left", (_state, _run) => [@moonstate.Write(add("left"))])
    .node("right", (_state, _run) => [@moonstate.Write(add("right"))])
    .edge("start", "left")
    .edge("start", "right")
    .compile("batched", executor=recorder) catch {
      refused => abort("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(recorder.batches.length(), 2)
  assert_eq(recorder.batches[0], ["start"])
  assert_eq(recorder.batches[1], ["left", "right"])
  assert_eq(recorder.attempts, [0, 0, 0])
  assert_eq(out.log, ["left", "right"])
}

///|
async test "a node that runs elsewhere answers in JSON and the run continues" {
  let graph = counter_builder()
    .entry("far")
    .node("far", (_state, _run) => [@moonstate.Write(add("here"))])
    .compile("remote", executor=Remote::{ }) catch {
      refused => abort("refused: " + (refused : Error).to_string())
    }
  let out = graph.run(seed(4)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  // The node never ran: the write came back from the executor as JSON.
  assert_eq(out.n, 104)
  assert_eq(out.log, ["remote"])
}

///|
/// The input of a work item is a function, not a value: an executor that does
/// not need to encode the state never pays for it.
async test "the input of a work item is encoded only when it is asked for" {
  let asked = Ref(0)
  let executor = { batches: [], attempts: [], }
  let graph = counter_builder()
    .entry("quiet")
    .node("quiet", (_state, _run) => [@moonstate.Write(add("quiet"))])
    .compile("lazy", executor~) catch {
      refused => abort("refused: " + (refused : Error).to_string())
    }
  let _ = graph.run(seed(0)) catch {
    error => fail("run: " + (error : Error).to_string())
  }
  assert_eq(asked.val, 0)
}
