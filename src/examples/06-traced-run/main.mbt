// A traced run: what the executor reports, as spans.
//
//     moon run src/examples/06-traced-run
//
// Without a collector the spans are printed where they end, which is enough to see
// the shape of a run: a span per superstep, a child span per node, and one span for
// the node that failed. With `MOONSTATE_LIVE` set they are exported over OTLP/gRPC
// to `127.0.0.1:4317` (or `MOONSTATE_TRACE_HOST` / `MOONSTATE_TRACE_PORT`), which is
// how the live check in CI feeds a registry validator with real telemetry.

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
/// Nanoseconds, from a clock that reports milliseconds. A span timestamp is
/// nanoseconds since the epoch; reading the millisecond clock and scaling it is the
/// closest a program that only has the platform clock can get.
fn nanos() -> Int64 {
  @env.now().reinterpret_as_int64() * 1_000_000L
}

///|
fn bytes(width : Int32) -> Bytes {
  match @env.rand(width) {
    Some(bytes) => bytes
    None => abort("the platform has no entropy source")
  }
}

///|
/// Three nodes in a line and a fourth that fails, so the trace has a success and a
/// failure in it.
async fn graph(executor : &@moonstate.Executor) -> Unit {
  let compiled = @moonstate.Builder::new(merge~, initial={ n: 0, })
    .entry("seed")
    .node("seed", (_state, _run) => [@moonstate.Write({ n: Some(1), })])
    .node("double", (state, _run) => {
      [@moonstate.Write({ n: Some(state.n * 2), })]
    })
    .node("stamp", (state, _run) => {
      [@moonstate.Write({ n: Some(state.n + 10), })]
    })
    .edge("seed", "double")
    .edge("double", "stamp")
    .compile("demo", executor~) catch {
      error =>
        abort("the graph does not compile: " + (error : Error).to_string())
    }
  let out = compiled.run({ n: None, }) catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  println("state: " + out.n.to_string())
  let failing = @moonstate.Builder::new(merge~, initial={ n: 0, })
    .entry("boom")
    .node("boom", (_state, _run) => {
      raise Failure::Failure("this node always fails")
      [@moonstate.Write({ n: Some(1), })]
    })
    .compile("failing", executor~) catch {
      error =>
        abort("the graph does not compile: " + (error : Error).to_string())
    }
  let _ = try {
    let _ = failing.run({ n: None, }, thread="broken")
    true
  } catch {
    _ => false
  }
}

///|
/// The spans as a tree: a span under the one it hangs off.
fn show(spans : Array[@trace.SpanData]) -> Unit {
  for span in spans {
    let indent = if span.parent is None { "" } else { "  " }
    println(
      indent +
      span.name +
      "  " +
      span.status.to_string() +
      "  " +
      span.duration().to_string() +
      " ns",
    )
    for attribute in span.attributes {
      println(indent + "  " + attribute.0 + " = " + attribute.1.to_string())
    }
  }
}

///|
async fn main {
  let live = @env.get_env_var("MOONSTATE_LIVE") is Some(_)
  if live {
    let host = match @env.get_env_var("MOONSTATE_TRACE_HOST") {
      Some(host) => host
      None => "127.0.0.1"
    }
    let port = 4317
    let transport = @grpc.GrpcTransport::connect(host~, port~)
    // No resource: a resource says which service produced the telemetry, and this
    // is a program that runs once and exits. A service sets its own, and the live
    // check in CI is about the names on the spans rather than about who sent them.
    let exporter = @otlp.TraceExporter::new(
      transport~,
      endpoint="http://" + host + ":" + port.to_string() + "/v1/traces",
      resource=@otlp.Resource::new(attributes=[]),
      format=@otlp.BodyFormat::Protobuf,
      now=nanos,
      rand=bytes,
    )
    let tracer = @trace.Tracer::new(
      rand=bytes,
      sink=exporter,
      sampler=@trace.parent_based(root=@trace.always),
    )
    let executor = @otel.traced(@moonstate.inline, tracer~, now=nanos)
    graph(executor)
    let report = exporter.flush()
    println(
      "exported " +
      report.delivered.to_string() +
      " spans in " +
      report.attempts.to_string() +
      " requests",
    )
    transport.close()
  } else {
    let recorder = @trace.Recorder::new()
    let tracer = @trace.Tracer::new(
      rand=bytes,
      sink=recorder,
      sampler=@trace.parent_based(root=@trace.always),
    )
    let executor = @otel.traced(@moonstate.inline, tracer~, now=nanos)
    graph(executor)
    show(recorder.spans())
  }
}
