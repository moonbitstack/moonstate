///|
/// A node queued for a superstep, as a checkpoint records it. `input` is the
/// state the node is handed: absent means the state as merged at that point,
/// present means a `Send` gave it its own.
#derive(@json.ToJson, @json.FromJson)
pub(all) struct Pending {
  node : String
  input : Json?
}

///|
pub extend Pending with @json.ToJson::{to_json}

///|
pub extend Pending with @json.FromJson::{from_json}

///|
/// The steps one task produced, kept apart from the checkpoint record so that a
/// finished task is never run twice after a crash.
#derive(@json.ToJson, @json.FromJson)
pub(all) struct TaskWrite {
  task : String
  values : Array[Json]
}

///|
pub extend TaskWrite with @json.ToJson::{to_json}

///|
pub extend TaskWrite with @json.FromJson::{from_json}

///|
/// One durable point in a thread's run: the state after `step` supersteps, the
/// tasks the next superstep will run, and the writes already collected for them.
/// A `Saver` stores these verbatim; the engine is the only thing that reads the
/// state back into its own type.
#derive(@json.ToJson, @json.FromJson)
pub(all) struct Checkpoint {
  thread : String
  ///
  /// Unique within the thread, and ordered by the saver.
  id : String
  ///
  /// The checkpoint this one was written on top of, or `None` for the first.
  parent : String?
  ///
  /// How many checkpoints the thread had written before this one. `id` is
  /// derived from it, so an `update` that forks the thread does not collide
  /// with the checkpoints it forked away from.
  seq : Int32
  ///
  /// The superstep this checkpoint is about to run.
  step : Int32
  ///
  /// The whole state, encoded.
  state : Json
  ///
  /// The tasks of the next superstep, in the order their writes will be merged.
  pending : Array[Pending]
  ///
  /// Set when the superstep was cut short by `Step::Interrupt`.
  interrupt : Json?
  created_at : Int64
  ///
  /// The writes recorded for this checkpoint's tasks. A saver fills this in when
  /// it reads the checkpoint back; it is never part of what `put` stores.
  writes : Array[TaskWrite]?
}

///|
pub extend Checkpoint with @json.ToJson::{to_json}

///|
pub extend Checkpoint with @json.FromJson::{from_json}

///|
/// A checkpoint seen through the graph's own state type: what a caller asks for
/// when it wants to look at a thread, not to resume it.
pub(all) struct Snapshot[S] {
  thread : String
  id : String
  parent : String?
  step : Int32
  state : S
  ///
  /// The nodes the next superstep would run. Empty when the run finished.
  next : Array[String]
  interrupt : Json?
  created_at : Int64
}
