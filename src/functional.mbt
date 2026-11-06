///|
/// The state a functional graph runs on: the input the entrypoint was called
/// with, and the value it returned. Keeping both as JSON is what makes a
/// half-finished entrypoint resumable — the input is still there to replay from.
#derive(@json.ToJson, @json.FromJson)
pub(all) struct Frame {
  input : Json
  output : Json?
}

///|
pub extend Frame with @json.ToJson::{to_json}

///|
pub extend Frame with @json.FromJson::{from_json}

///|
fn merge_frame(state : Frame, update : Frame) -> Frame {
  {
    input: update.input,
    output: match update.output {
      Some(output) => Some(output)
      None => state.output
    },
  }
}

///|
/// A step that is recorded when it finishes. Calling one through `Task::call`
/// writes its result to the checkpoint before the entrypoint moves on, so a run
/// that replays after a crash reuses the result instead of doing the work twice.
pub struct Task[I, O] {
  name : String
  run : async (I) -> O
  retry : Retry?
}

///|
pub fn[I, O] task(
  name : String,
  run : async (I) -> O,
  retry? : Retry,
) -> Task[I, O] {
  { name, run, retry, }
}

///|
/// What an entrypoint hands its body: the run it belongs to, and the machinery a
/// task call needs. One context per attempt; `call` advances it, which is how a
/// replayed run lines its calls up with the recorded ones.
pub struct Context {
  run : Run
  saver : &Saver?
  executor : &Executor
  graph : String
  mut index : Int32
  recorded : Map[String, Json]
}

///|
/// How many task calls this attempt has made so far.
pub fn Context::index(self : Context) -> Int32 {
  self.index
}

///|
/// The run this entrypoint belongs to.
pub fn Context::run(self : Context) -> Run {
  self.run
}

///|
fn call_key(index : Int32, name : String) -> String {
  "call:" + index.to_string() + ":" + name
}

///|
/// Call a task: return its recorded result if this call already ran before the
/// crash, otherwise run it and record what it returned.
pub async fn[I : @json.ToJson, O : @json.ToJson + @json.FromJson] Task::call(
  self : Task[I, O],
  context : Context,
  input : I,
) -> O raise GraphError {
  let key = call_key(context.index, self.name)
  context.index = context.index + 1
  match context.recorded.get(key) {
    Some(json) =>
      @json.from_json(json) catch {
        error =>
          raise GraphError::Unreadable(
            reason="task '" + self.name + "': " + error_text(error),
          )
      }
    None => {
      let work = {
        graph: context.graph,
        node: "task:" + self.name,
        thread: context.run.thread(),
        step: context.run.step(),
        attempt: 0,
        input: fn() { @json.to_json(input) },
        run: async fn() { [@json.to_json((self.run)(input))] },
      }
      let value = run_task(self, context, work)
      match context.saver {
        Some(saver) =>
          note_writes(
            saver,
            context.run.thread(),
            context.run.checkpoint(),
            key,
            [value],
          )
        None => ()
      }
      context.recorded[key] = value
      @json.from_json(value) catch {
        error =>
          raise GraphError::Unreadable(
            reason="task '" + self.name + "': " + error_text(error),
          )
      }
    }
  }
}

///|
async fn[I, O] run_task(
  spec : Task[I, O],
  context : Context,
  work : Work,
) -> Json raise GraphError {
  let mut attempt : Int32 = 0
  let attempts = match spec.retry {
    Some(retry) => retry.attempts
    None => 1
  }
  while true {
    let done = execute(context.executor, [work])
    let result = done[0]
    match result.error {
      None => return result.values.unwrap_or([Json::null()])[0]
      Some(message) => {
        if attempt + 1 >= attempts {
          raise GraphError::NodeFailed(node=spec.name, message~)
        }
        attempt = attempt + 1
        match spec.retry {
          Some(retry) => if retry.delay > 0 { pause(retry.delay) }
          None => ()
        }
      }
    }
  }
  abort("unreachable")
}

///|
/// A graph built from one function: the function is the only node, and every
/// `Task::call` inside it is a durable step of that node.
pub struct Entrypoint[I, O] {
  graph : Graph[Frame, Frame]
  encode : (I) -> Json
  decode : (Json) -> O raise GraphError
}

///|
/// Wrap `body` as a graph with one node. The body may call tasks; each call is
/// recorded, and a resumed run replays the body from the start and reuses the
/// results. The body itself has to be deterministic apart from those calls —
/// replaying it is how the run gets back to where it stopped.
pub fn[I : @json.ToJson + @json.FromJson, O : @json.ToJson + @json.FromJson] entrypoint(
  name : String,
  body : async (I, Context) -> O,
  saver? : &Saver,
  store? : &Store,
  executor? : &Executor,
  limit? : Int32,
) -> Entrypoint[I, O] raise Refused {
  let node = async fn(frame : Frame, run : Run) -> Array[Step[Frame, Frame]] {
    let input : I = @json.from_json(frame.input) catch {
      error =>
        raise GraphError::Unreadable(
          reason="entrypoint input: " + error_text(error),
        )
    }
    let recorded : Map[String, Json] = Map([])
    for write in run.writes() {
      if write.task.has_prefix("call:") && write.values.length() > 0 {
        recorded[write.task] = write.values[0]
      }
    }
    let context = {
      run,
      saver,
      executor: match executor {
        Some(executor) => executor
        None => inline
      },
      graph: name,
      index: 0,
      recorded,
    }
    let output = body(input, context)
    [Write({ input: frame.input, output: Some(@json.to_json(output)), })]
  }
  let graph = Builder::new(merge=merge_frame, initial={
      input: Json::null(),
      output: None,
    })
    .entry("entrypoint")
    .node("entrypoint", node)
    .compile(name, saver?, store?, executor?, limit?)
  {
    graph,
    encode: input => @json.to_json(input),
    decode: output => {
      @json.from_json(output) catch {
        error =>
          raise GraphError::Unreadable(
            reason="entrypoint output: " + error_text(error),
          )
      }
    },
  }
}

///|
/// Run the entrypoint and return what its body returned.
pub async fn[I, O] Entrypoint::run(
  self : Entrypoint[I, O],
  input : I,
  thread? : String,
) -> O raise GraphError {
  let frame = self.graph.run(
    { input: (self.encode)(input), output: None, },
    thread?,
  )
  match frame.output {
    Some(output) => (self.decode)(output)
    None => raise GraphError::Unreadable(reason="entrypoint produced no output")
  }
}
