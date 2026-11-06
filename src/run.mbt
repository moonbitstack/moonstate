///|
/// What a node is handed besides the state: which thread it belongs to, which
/// superstep it is running in, where to put long-term memory, how to report
/// progress, and how to stop.
///
/// A run handle belongs to one task. Calling `cancel` on it stops the thread at
/// the next superstep boundary — never in the middle of a node, so what a node
/// wrote before asking to stop is kept.
pub struct Run {
  thread : String
  step : Int32
  checkpoint : String
  answer : Json?
  store : &Store?
  saver : &Saver?
  cancelled : Ref[Bool]
  emit : (Json) -> Unit
  writes : Array[TaskWrite]
}

///|
pub fn Run::thread(self : Run) -> String {
  self.thread
}

///|
/// The superstep this task belongs to, counting from zero.
pub fn Run::step(self : Run) -> Int32 {
  self.step
}

///|
/// The checkpoint this superstep's writes are filed under. A node that keeps
/// its own progress in `Saver::put_writes` needs it.
pub fn Run::checkpoint(self : Run) -> String {
  self.checkpoint
}

///|
/// The answer `resume` was called with, for the node that asked for it.
pub fn Run::answer(self : Run) -> Json? {
  self.answer
}

///|
/// The saver the graph was compiled with, if any. A node that runs another graph
/// hands it on, so the child's checkpoints land next to the parent's.
pub fn Run::saver(self : Run) -> &Saver? {
  self.saver
}

///|
/// The long-term store the graph was compiled with, if any.
pub fn Run::store(self : Run) -> &Store? {
  self.store
}

///|
/// Report progress to whoever is streaming this run. Does nothing when nobody is.
pub fn Run::emit(self : Run, value : Json) -> Unit {
  (self.emit)(value)
}

///|
/// Ask the thread to stop at the next superstep boundary.
pub fn Run::cancel(self : Run) -> Unit {
  self.cancelled.val = true
}

///|
pub fn Run::is_cancelled(self : Run) -> Bool {
  self.cancelled.val
}

///|
/// The writes already recorded for this checkpoint's tasks. A node that runs
/// other durable steps itself — the functional form does — reads them back here
/// to skip work a crashed run had already finished.
pub fn Run::writes(self : Run) -> Array[TaskWrite] {
  self.writes
}
