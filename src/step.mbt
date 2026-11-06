///|
/// What one node contributes to the superstep it took part in. A node returns a
/// list of these, applied in the order it wrote them: writes fold into the state,
/// `Goto` and `Send` decide who runs next, and `Interrupt` stops the run there.
pub(all) enum Step[S, U] {
  ///
  /// Fold `U` into the state with the graph's merge function.
  Write(U)
  ///
  /// Leave the node's declared successors behind and run this node next.
  Goto(String)
  ///
  /// Queue this node for the next superstep with its own input state, which is
  /// how a fan-out hands each branch a different slice of the work.
  Send(String, S)
  ///
  /// Stop before the next superstep and wait for `resume`. The node that
  /// returned this runs again from the same input when the thread resumes, and
  /// reads the answer through `Run::answer`.
  Interrupt(Json)
}

///|
/// The wire form of a step: what a `Work` carries back from wherever the node
/// ran. Executors only ever see this, which is what lets a node run in another
/// process without the graph itself crossing the boundary.
pub fn[S : @json.ToJson, U : @json.ToJson] Step::encode(
  self : Step[S, U],
) -> Json {
  match self {
    Write(update) => { "kind": "write", "value": @json.to_json(update) }
    Goto(to) => { "kind": "goto", "to": to }
    Send(to, input) =>
      { "kind": "send", "to": to, "input": @json.to_json(input) }
    Interrupt(value) => { "kind": "interrupt", "value": value }
  }
}

///|
fn[S : @json.FromJson] decode_field(
  fields : Map[String, Json],
  key : String,
) -> S raise GraphError {
  let value = match fields.get(key) {
    Some(value) => value
    None =>
      raise GraphError::Unreadable(reason="step has no '" + key + "' field")
  }
  @json.from_json(value) catch {
    error =>
      raise GraphError::Unreadable(
        reason="step field '" + key + "': " + error_text(error),
      )
  }
}

///|
/// Read back a step written by `encode`. A step that cannot be decoded cannot be
/// applied, and guessing at it would corrupt the state silently.
pub fn[S : @json.FromJson, U : @json.FromJson] Step::decode(
  json : Json,
) -> Step[S, U] raise GraphError {
  guard json is Object(fields) else {
    raise GraphError::Unreadable(reason="step is not a JSON object")
  }
  let kind = match fields.get("kind") {
    Some(String(kind)) => kind
    _ => raise GraphError::Unreadable(reason="step has no 'kind'")
  }
  match kind {
    "write" => Write(decode_field(fields, "value"))
    "goto" => Goto(decode_field(fields, "to"))
    "send" => Send(decode_field(fields, "to"), decode_field(fields, "input"))
    "interrupt" =>
      Interrupt(
        match fields.get("value") {
          Some(value) => value
          None =>
            raise GraphError::Unreadable(reason="interrupt step has no 'value'")
        },
      )
    _ => raise GraphError::Unreadable(reason="unknown step kind '" + kind + "'")
  }
}

///|
fn[S : @json.FromJson, U : @json.FromJson] decode_steps(
  raw : Array[Json],
) -> Array[Step[S, U]] raise GraphError {
  let steps = []
  for json in raw {
    steps.push(Step::decode(json))
  }
  steps
}
