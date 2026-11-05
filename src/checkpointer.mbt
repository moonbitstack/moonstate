// Agent checkpointing (Koog `agents-features-snapshot`). The checkpoint record and its storage
// provider live in `persistence`, which is pure and builds on every backend; the agent package
// only names them, so `@agent.AgentCheckpoint` and `AgentCheckpoint` are one type
// rather than two that drift apart.

///|
/// The checkpoint record and its in-memory store, re-exported under `@agent`.
pub using @persistence {type AgentCheckpoint, type InMemoryPersistence}

///|
/// Where a run's node-boundary snapshots go: the store, the session id they are filed under, and
/// the clock that stamps them. MoonBit has no ambient clock, so a caller that cares about wall
/// time supplies one; without it a checkpoint is stamped with its sequence number, which orders
/// a session's checkpoints correctly and keeps tests deterministic.
pub struct Checkpointer {
  store : &PersistenceStorageProvider
  session : String
  clock : (() -> Int64)?
  mut seq : Int32
}

///|
/// Snapshot every node boundary of a run into `store` under `session`.
pub fn Checkpointer::new(
  store : &PersistenceStorageProvider,
  session~ : String,
  clock? : () -> Int64,
) -> Checkpointer {
  { store, session, clock, seq: 0, }
}

///|
/// The stamp for the next checkpoint.
fn Checkpointer::now(self : Checkpointer) -> Int64 {
  match self.clock {
    Some(read) => read()
    None => self.seq.to_int64()
  }
}
