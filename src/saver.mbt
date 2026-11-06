///|
/// Where a thread's checkpoints live. The engine writes one per superstep and
/// reads the last one back to resume, so an implementation only has to store
/// records and hand them back in order.
pub(open) trait Saver {
  ///|
  /// The checkpoint with `id`, or the thread's latest when `id` is absent.
  async fn get(Self, thread : String, id? : String) -> Checkpoint?
  ///|
  /// Store a checkpoint. Writing the same id twice replaces it.
  async fn put(Self, Checkpoint) -> Unit
  ///|
  /// Record what one task of checkpoint `id` produced, before the superstep
  /// finishes. A resumed run skips tasks that already have writes here.
  async fn put_writes(
    Self,
    thread : String,
    id : String,
    task : String,
    values : Array[Json],
  ) -> Unit
  ///|
  /// A thread's checkpoints in the order they were written. `limit` keeps the
  /// most recent ones, `before` keeps those written before that checkpoint id.
  async fn list(Self, thread : String, limit? : Int32, before? : String) -> Array[
    Checkpoint,
  ]
  ///|
  /// Drop a thread entirely: checkpoints and writes.
  async fn delete(Self, thread : String) -> Unit
}

///|
/// A saver that keeps everything in memory: enough for a run that has to survive
/// a failed node, not the process it runs in.
pub struct MemorySaver {
  threads : Map[String, Array[Checkpoint]]
  writes : Map[String, Array[TaskWrite]]
}

///|
pub fn MemorySaver::new() -> MemorySaver {
  { threads: Map([]), writes: Map([]), }
}

///|
fn bucket_key(thread : String, id : String) -> String {
  thread + "\u{1f}" + id
}

///|
fn MemorySaver::bucket(
  self : MemorySaver,
  thread : String,
) -> Array[Checkpoint] {
  match self.threads.get(thread) {
    Some(all) => all
    None => {
      let all = []
      self.threads[thread] = all
      all
    }
  }
}

///|
pub impl Saver for MemorySaver with fn get(self, thread, id?) -> Checkpoint? raise {
  let all = self.bucket(thread)
  let found = match id {
    Some(want) => all.iter().find_first(cp => cp.id == want)
    None => all.last()
  }
  match found {
    None => None
    Some(cp) =>
      Some({ ..cp, writes: self.writes.get(bucket_key(thread, cp.id)), })
  }
}

///|
pub impl Saver for MemorySaver with fn put(self, checkpoint) -> Unit raise {
  let all = self.bucket(checkpoint.thread)
  let stored = { ..checkpoint, writes: None, }
  let mut replaced = false
  for i = 0; i < all.length(); i = i + 1 {
    if all[i].id == checkpoint.id {
      all[i] = stored
      replaced = true
    }
  }
  if !replaced {
    all.push(stored)
  }
}

///|
pub impl Saver for MemorySaver with fn put_writes(
  self,
  thread,
  id,
  task,
  values,
) -> Unit raise {
  let key = bucket_key(thread, id)
  let recorded = match self.writes.get(key) {
    Some(recorded) => recorded
    None => {
      let recorded = []
      self.writes[key] = recorded
      recorded
    }
  }
  for i = 0; i < recorded.length(); i = i + 1 {
    if recorded[i].task == task {
      recorded[i] = { task, values, }
      return
    }
  }
  recorded.push({ task, values, })
}

///|
pub impl Saver for MemorySaver with fn list(self, thread, limit?, before?) -> Array[
  Checkpoint,
] raise {
  let kept = []
  for cp in self.bucket(thread) {
    let is_before = match before {
      Some(id) => cp.id < id
      None => true
    }
    if is_before {
      kept.push({ ..cp, writes: self.writes.get(bucket_key(thread, cp.id)), })
    }
  }
  match limit {
    Some(n) => kept.rev()[:n].rev()
    None => kept
  }
}

///|
pub impl Saver for MemorySaver with fn delete(self, thread) -> Unit raise {
  self.threads.remove(thread)
  let prefix = thread + "\u{1f}"
  let stale = []
  for key, _ in self.writes {
    if key.has_prefix(prefix) {
      stale.push(key)
    }
  }
  for key in stale {
    self.writes.remove(key)
  }
}

///|
pub extend MemorySaver with Saver::{get, put, put_writes, list, delete}
