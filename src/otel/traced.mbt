///|
/// An executor that reports what it runs: one span per superstep, and one child
/// span per node inside that superstep.
///
/// A trace follows a thread from superstep to superstep — each superstep span is a
/// child of the previous one — so a run is one trace however many supersteps it
/// takes, and a node's span sits under the superstep that ran it. Two threads
/// sharing the executor get two traces, because the chain is kept per thread.
pub struct Traced {
  inner : &@moonstate.Executor
  tracer : @trace.Tracer
  now : () -> Int64
  /// The span the next superstep of a thread hangs off. Kept per thread, because
  /// the engine runs supersteps one at a time but several threads at once.
  last : Map[String, @trace.TraceContext]
}

///|
/// Wrap `inner` so every task it runs is traced. `now` supplies the nanosecond
/// timestamps; this library does not read a clock of its own, so a replay can run
/// on a timeline the caller chose.
pub fn traced(
  inner : &@moonstate.Executor,
  tracer~ : @trace.Tracer,
  now~ : () -> Int64,
) -> Traced {
  { inner, tracer, now, last: Map([]), }
}

///|
/// The name a superstep span carries. The step number is bounded by the graph's
/// limit, so it costs nothing in cardinality and saves a lookup.
fn superstep_name(step : Int32) -> String {
  "superstep " + step.to_string()
}

///|
fn Traced::start_superstep(
  self : Traced,
  parent : @trace.TraceContext?,
  graph : String,
  thread : String,
  step : Int32,
) -> @trace.Span? {
  let attributes : Array[(String, @trace.Value)] = [
    (@semconv.gen_ai_operation_name, @trace.Value::Str("invoke_agent")),
    (@semconv.gen_ai_agent_name, @trace.Value::Str(graph)),
    (@semconv.gen_ai_conversation_id, @trace.Value::Str(thread)),
  ]
  let at = (self.now)()
  try {
    match parent {
      Some(parent) =>
        Some(
          self.tracer.start(
            superstep_name(step),
            parent~,
            kind=@trace.SpanKind::Internal,
            at~,
            attributes~,
          ),
        )
      None =>
        Some(
          self.tracer.start(
            superstep_name(step),
            kind=@trace.SpanKind::Internal,
            at~,
            attributes~,
          ),
        )
    }
  } catch {
    // A tracer that refuses the ids it generated leaves the run untraced rather
    // than stopping it: telemetry that breaks the work it measures is worse than
    // telemetry that is missing.
    _ => None
  }
}

///|
fn Traced::start_node(
  self : Traced,
  parent : @trace.Span?,
  work : @moonstate.Work,
) -> @trace.Span? {
  let attributes : Array[(String, @trace.Value)] = [
    (@semconv.gen_ai_operation_name, @trace.Value::Str("execute_tool")),
    (@semconv.gen_ai_tool_name, @trace.Value::Str(work.node)),
    (@semconv.gen_ai_conversation_id, @trace.Value::Str(work.thread)),
    (
      @semconv.gen_ai_tool_call_id,
      @trace.Value::Str(
        work.thread +
        ":" +
        work.step.to_string() +
        ":" +
        work.node +
        ":" +
        work.attempt.to_string(),
      ),
    ),
  ]
  let at = (self.now)()
  try {
    match parent {
      Some(parent) =>
        Some(
          self.tracer.start(
            work.node,
            parent=parent.context(),
            kind=@trace.SpanKind::Internal,
            at~,
            attributes~,
          ),
        )
      None =>
        Some(
          self.tracer.start(
            work.node,
            kind=@trace.SpanKind::Internal,
            at~,
            attributes~,
          ),
        )
    }
  } catch {
    _ => None
  }
}

///|
/// The task with a span around it: the span ends when the node does, before the
/// executor turns a failure into a `Done`, so a retry is a second span next to the
/// first rather than one span that grew.
fn Traced::around(
  self : Traced,
  parent : @trace.Span?,
  work : @moonstate.Work,
) -> @moonstate.Work {
  let span = self.start_node(parent, work)
  let run = async fn() {
    let outcome = Ok((work.run)()) catch { error => Err(error) }
    match span {
      Some(span) =>
        match outcome {
          Ok(values) => {
            span.set_status(@trace.Status::Ok)
            span.finish(at=(self.now)())
            values
          }
          Err(error) => {
            span.record_exception(message="\{error}", at=(self.now)())
            span.set_status(@trace.Status::Error("\{error}"))
            span.finish(at=(self.now)())
            raise error
          }
        }
      None =>
        match outcome {
          Ok(values) => values
          Err(error) => raise error
        }
    }
  }
  { ..work, run, }
}

///|
pub impl @moonstate.Executor for Traced with fn each(self, works) -> Array[
  @moonstate.Done,
] raise {
  guard works.length() > 0 else { return self.inner.each(works) }
  let first = works[0]
  let superstep = self.start_superstep(
    self.last.get(first.thread),
    first.graph,
    first.thread,
    first.step,
  )
  let traced : Array[@moonstate.Work] = []
  for work in works {
    traced.push(self.around(superstep, work))
  }
  let done = self.inner.each(traced)
  match superstep {
    Some(span) => {
      let mut failed = false
      for result in done {
        if result.error is Some(_) {
          failed = true
        }
      }
      if failed {
        span.set_status(@trace.Status::Error("a node of the superstep failed"))
      } else {
        span.set_status(@trace.Status::Ok)
      }
      span.finish(at=(self.now)())
      self.last[first.thread] = span.context()
    }
    None => ()
  }
  done
}

///|
pub extend Traced with @moonstate.Executor::{each}
