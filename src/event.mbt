///|
/// What a run reports while it happens. The stream modes of a graph engine are
/// one type here: the caller takes the variants it needs and ignores the rest.
pub(all) enum Event[S, U] {
  ///
  /// The whole state after a superstep.
  Values(S)
  ///
  /// One node's write, as it is folded in. Several arrive per superstep.
  Updates(node~ : String, U)
  ///
  /// Whatever a node passed to `Run::emit`.
  Custom(node~ : String, Json)
  ///
  /// A node has been handed to the executor.
  Started(node~ : String)
  ///
  /// A node finished and its steps are about to be applied.
  Finished(node~ : String)
  ///
  /// The run stopped and is waiting for `resume` with this value.
  Interrupted(Json)
}
