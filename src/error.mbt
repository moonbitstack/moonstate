///|
/// Why a graph definition was refused when it was compiled. Every check here is
/// structural: the nodes and edges are known then, the runs are not.
pub(all) suberror Refused {
  NoNodes
  NoEntry
  UnknownEntry(node~ : String)
  DuplicateNode(node~ : String)
  DanglingEdge(from~ : String, to~ : String)
  Unreachable(node~ : String)
  NoExit
}

///|
/// Why a run could not finish.
pub(all) suberror GraphError {
  ///
  /// The run took `limit` supersteps without reaching an end.
  StepLimit(limit~ : Int32)
  ///
  /// A node raised, after its retries if it had any; `message` is the error text.
  NodeFailed(node~ : String, message~ : String)
  ///
  /// A node asked to stop and wait for an answer. `resume` continues the thread.
  Interrupted(thread~ : String, value~ : Json)
  ///
  /// `resume` was called on a thread with nothing to continue.
  NotInterrupted(thread~ : String)
  ///
  /// The thread has no checkpoint the saver knows about.
  MissingThread(thread~ : String)
  ///
  /// A node routed the run to a name the graph does not define. The compile-time
  /// check cannot see the names a `Goto`, a `Send` or a branch picks, so the run
  /// reports them the first time one is taken.
  MissingNode(node~ : String)
  ///
  /// A checkpoint could not be decoded back into the graph's state type.
  Unreadable(reason~ : String)
  ///
  /// A node cancelled the run, or the caller did before the next superstep.
  Cancelled(thread~ : String)
  ///
  /// A saver, a store, an executor or a stream callback raised. The engine keeps
  /// going only where it can tell what went wrong, so this is where an outside
  /// failure ends up.
  Backend(reason~ : String)
}

///|
/// The text of an error. The default rendering of a sub-error drops its payload,
/// and the payload is the whole point of a failure report that crosses a process
/// boundary, so the fields are spelled out here.
fn error_text(error : Error) -> String {
  match error {
    Refused::NoNodes => "the graph has no nodes"
    Refused::NoEntry => "the graph has no entry node"
    Refused::UnknownEntry(node~) => "the entry names no node: " + node
    Refused::DuplicateNode(node~) => "the node is defined twice: " + node
    Refused::DanglingEdge(from~, to~) =>
      "the edge " + from + " -> " + to + " names a node that is not defined"
    Refused::Unreachable(node~) => "no path reaches the node: " + node
    Refused::NoExit => "no node ends the graph"
    GraphError::StepLimit(limit~) =>
      "the run took " + limit.to_string() + " supersteps without ending"
    GraphError::NodeFailed(node~, message~) =>
      "node '" + node + "' failed: " + message
    GraphError::Interrupted(thread~, value~) =>
      "thread '" + thread + "' waits for an answer: " + value.stringify()
    GraphError::NotInterrupted(thread~) =>
      "thread '" + thread + "' has nothing to continue"
    GraphError::MissingThread(thread~) => "no thread named '" + thread + "'"
    GraphError::MissingNode(node~) => "no node named '" + node + "'"
    GraphError::Unreadable(reason~) =>
      "a checkpoint could not be read: " + reason
    GraphError::Cancelled(thread~) => "thread '" + thread + "' was cancelled"
    GraphError::Backend(reason~) => reason
    Failure::Failure(message) => message
    _ => error.to_string()
  }
}
