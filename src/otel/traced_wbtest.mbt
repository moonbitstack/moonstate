// The traced executor, checked against moontel's recording sink: what the spans
// are called, what they hang off, and what a failure looks like on one.

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
/// A clock that counts in whole nanoseconds from a fixed origin, so every span in a
/// test sits on a timeline the test wrote.
fn step_clock() -> () -> Int64 {
  let now = Ref(1000L)
  () => {
    now.val = now.val + 100L
    now.val
  }
}

///|
/// A source of randomness that counts, so each span gets ids of its own.
fn counting_rand() -> (Int32) -> Bytes {
  let calls = Ref(0)
  width => {
    calls.val = calls.val + 1
    let bytes : Array[Byte] = []
    for i = 0; i < width; i = i + 1 {
      bytes.push(((calls.val * 31 + i + 1) % 251 + 1).to_byte())
    }
    Bytes::from_array(bytes)
  }
}

///|
fn recording_tracer(recorder : @trace.Recorder) -> @trace.Tracer {
  @trace.Tracer::new(rand=counting_rand(), sink=recorder, sampler=@trace.always)
}

///|
/// A line of three nodes, run once.
fn line_graph(
  executor : &@moonstate.Executor,
) -> @moonstate.Graph[Counter, Patch] {
  @moonstate.Builder::new(merge~, initial={ n: 0, })
  .entry("seed")
  .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(1), })])
  .node("double", (state, _run) => [@moonstate.Write({ n: Some(state.n * 2), })])
  .node("stamp", (state, _run) => [@moonstate.Write({ n: Some(state.n + 10), })])
  .edge("seed", "double")
  .edge("double", "stamp")
  .compile("line", executor~) catch {
    error =>
      abort("the line graph does not compile: " + (error : Error).to_string())
  }
}

///|
/// The attribute named `name` on a span, as text.
fn attribute(span : @trace.SpanData, name : String) -> String? {
  for entry in span.attributes {
    let (key, value) = entry
    if key == name {
      return Some(
        match value {
          @trace.Value::Str(text) => text
          other => other.to_string()
        },
      )
    }
  }
  None
}

///|
async test "each node gets a span under the superstep that ran it" {
  let recorder = @trace.Recorder::new()
  let tracer = recording_tracer(recorder)
  let executor = traced(@moonstate.inline, tracer~, now=step_clock())
  let graph = line_graph(executor)
  let out = graph.run({ n: None, }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  assert_eq(out.n, 12)
  let spans = recorder.spans()
  // Three supersteps, one node each, and a span for each of the two.
  assert_eq(spans.length(), 6)
  let names = spans.map(span => span.name)
  assert_true(names.contains("superstep 0"))
  assert_true(names.contains("superstep 1"))
  assert_true(names.contains("superstep 2"))
  assert_true(names.contains("seed"))
  assert_true(names.contains("double"))
  assert_true(names.contains("stamp"))
}

///|
async test "a run is one trace, chained through its supersteps" {
  let recorder = @trace.Recorder::new()
  let tracer = recording_tracer(recorder)
  let executor = traced(@moonstate.inline, tracer~, now=step_clock())
  let graph = line_graph(executor)
  let _ = graph.run({ n: None, }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  let spans = recorder.spans()
  let first = spans[0].context.trace_id
  for span in spans {
    assert_eq(span.context.trace_id, first)
  }
  // The node spans hang off their superstep, and the supersteps hang off each
  // other: exactly one span has no parent.
  let roots = spans.filter(span => span.parent is None)
  assert_eq(roots.length(), 1)
  assert_eq(roots[0].name, "superstep 0")
}

///|
async test "the spans carry the semantic conventions' names, not made-up ones" {
  let recorder = @trace.Recorder::new()
  let tracer = recording_tracer(recorder)
  let executor = traced(@moonstate.inline, tracer~, now=step_clock())
  let graph = line_graph(executor)
  let _ = graph.run({ n: None, }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  let spans = recorder.spans()
  let node = spans.iter().find_first(span => span.name == "double").unwrap()
  assert_eq(attribute(node, "gen_ai.tool.name"), Some("double"))
  assert_eq(attribute(node, "gen_ai.operation.name"), Some("execute_tool"))
  assert_eq(attribute(node, "gen_ai.conversation.id"), Some("default"))
  let superstep = spans
    .iter()
    .find_first(span => span.name == "superstep 0")
    .unwrap()
  assert_eq(attribute(superstep, "gen_ai.agent.name"), Some("line"))
  assert_eq(attribute(superstep, "gen_ai.operation.name"), Some("invoke_agent"))
}

///|
async test "a failing node ends its span with the error on it" {
  let recorder = @trace.Recorder::new()
  let tracer = recording_tracer(recorder)
  let executor = traced(@moonstate.inline, tracer~, now=step_clock())
  let graph = @moonstate.Builder::new(merge~, initial={ n: 0, })
    .entry("boom")
    .node("boom", (_state, _run) => {
      raise Failure::Failure("no good")
      [@moonstate.Write({ n: Some(1), })]
    })
    .compile("fail", executor~) catch {
      error =>
        abort(
          "the failing graph does not compile: " + (error : Error).to_string(),
        )
    }
  let _ = try {
    let _ = graph.run({ n: None, })
    true
  } catch {
    _ => false
  }
  let spans = recorder.spans()
  let node = spans.iter().find_first(span => span.name == "boom").unwrap()
  match node.status {
    @trace.Status::Error(message) => assert_true(message.contains("no good"))
    _ => fail("the node span is not an error")
  }
  // The superstep that ran it is an error too, and the exception is on the node.
  let superstep = spans
    .iter()
    .find_first(span => span.name == "superstep 0")
    .unwrap()
  assert_true(superstep.status is @trace.Status::Error(_))
  assert_eq(node.events.length(), 1)
}

///|
async test "two threads are two traces, not one" {
  let recorder = @trace.Recorder::new()
  let tracer = recording_tracer(recorder)
  let executor = traced(@moonstate.inline, tracer~, now=step_clock())
  let graph = line_graph(executor)
  let _ = graph.run({ n: None, }, thread="one") catch {
    error => abort("the first run failed: " + (error : Error).to_string())
  }
  let _ = graph.run({ n: None, }, thread="two") catch {
    error => abort("the second run failed: " + (error : Error).to_string())
  }
  let spans = recorder.spans()
  let traces : Array[Bytes] = []
  for span in spans {
    if !traces.contains(span.context.trace_id) {
      traces.push(span.context.trace_id)
    }
  }
  assert_eq(traces.length(), 2)
  // Both inherited the same conversation id rule, so the traces are told apart by
  // what is on the span rather than by the id alone.
  let conversations : Array[String] = []
  for span in spans {
    match attribute(span, "gen_ai.conversation.id") {
      Some(value) =>
        if !conversations.contains(value) {
          conversations.push(value)
        }
      None => ()
    }
  }
  conversations.sort()
  assert_eq(conversations, ["one", "two"])
}
