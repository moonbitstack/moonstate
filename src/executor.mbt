///|
/// One node's turn to run, as the executor sees it. `input` is a function so the
/// state is encoded only when it actually crosses a process boundary; `run` is
/// what an in-process executor calls, and what an executor that ships the task
/// elsewhere ignores — it finds the node by `graph` and `node` on the far side.
pub(all) struct Work {
  graph : String
  node : String
  thread : String
  step : Int32
  attempt : Int32
  input : () -> Json
  run : async () -> Array[Json]
}

///|
/// What an executor reports back for one work item. Exactly one of `values` and
/// `error` is set: a failed node's error travels as text, because the executor
/// may not share a process with the graph that would have to match on it.
pub(all) struct Done {
  values : Array[Json]?
  error : String?
}

///|
/// Where a superstep's tasks run. The engine hands over the whole superstep at
/// once, which is what makes a fan-out parallel; the results come back in the
/// order the work was given, so merging stays deterministic.
pub(open) trait Executor {
  async fn each(Self, Array[Work]) -> Array[Done]
}

///|
/// Runs every task of a superstep in this process, concurrently.
priv struct Inline {}

///|
impl Executor for Inline with fn each(_self, works) -> Array[Done] raise {
  let jobs : Array[async () -> Done] = []
  for work in works {
    jobs.push(async fn() {
      let outcome = Ok((work.run)()) catch { error => Err(error) }
      match outcome {
        Ok(values) => { values: Some(values), error: None, }
        Err(error) => { values: None, error: Some(error_text(error)), }
      }
    })
  }
  @async.all(jobs[:])
}

///|
/// The default executor: every task in this process, at the same time.
pub let inline : &Executor = Inline::{ }
