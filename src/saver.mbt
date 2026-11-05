///|
/// A snapshot of an agent's run at a node boundary (Koog `AgentCheckpointData` with its
/// `GraphCheckpointProperties`): the conversation so far, the LLM configuration that produced
/// it, the serialized `AIAgentStorage`, and where the strategy graph had reached — the node
/// about to run (`node_id`) and the value flowing into it (`last_input`). Restoring replays
/// `message_history` and resumes the walk at `node_id`.
///
/// `created_at` is caller-supplied: MoonBit has no ambient clock, and a supplied one keeps a
/// test's checkpoints deterministic.
pub(all) struct AgentCheckpoint {
  checkpoint_id : String
  created_at : Int64
  message_history : Array[@prompt.Message]
  llm_params : @prompt.LLMParams?
  llm_model : @llm.LLModel?
  tools : Array[String]?
  storage : Json
  node_id : String
  last_input : Json?
  agent_iterations : Int32
  version : Int64
} derive(Eq, Debug)

///|
/// A checkpoint with only the fields a resume needs stated; the rest carry empty defaults, so
/// a caller that keeps no LLM configuration or storage need not spell them out.
pub fn AgentCheckpoint::new(
  checkpoint_id~ : String,
  created_at~ : Int64,
  node_id~ : String,
  message_history~ : Array[@prompt.Message] = [],
  llm_params? : @prompt.LLMParams,
  llm_model? : @llm.LLModel,
  tools? : Array[String],
  storage~ : Json = Json::object({}),
  last_input? : Json,
  agent_iterations~ : Int32 = 0,
  version~ : Int64 = 1L,
) -> AgentCheckpoint {
  {
    checkpoint_id,
    created_at,
    message_history,
    llm_params,
    llm_model,
    tools,
    storage,
    node_id,
    last_input,
    agent_iterations,
    version,
  }
}

///|
/// The checkpoint storage contract (Koog `PersistenceStorageProvider`): save a
/// checkpoint under a session, list a session's checkpoints, or fetch its latest.
pub(open) trait PersistenceStorageProvider {
  fn save_checkpoint(Self, session_id : String, checkpoint : AgentCheckpoint) -> Unit
  fn get_checkpoints(Self, session_id : String) -> Array[AgentCheckpoint]
  fn get_latest_checkpoint(Self, session_id : String) -> AgentCheckpoint?
}

///|
/// An in-memory `PersistenceStorageProvider` (Koog `InMemoryPersistencyStorageProvider`):
/// checkpoints kept per session in save order.
pub struct InMemoryPersistence {
  by_session : Map[String, Array[AgentCheckpoint]]
}

///|
/// An empty in-memory checkpoint store.
pub fn InMemoryPersistence::new() -> InMemoryPersistence {
  { by_session: Map([]), }
}

///|
/// The store's behaviour lives in these three, so the inherent methods and the trait impls
/// below are the same code seen through two names rather than one calling the other.
fn InMemoryPersistence::put(
  self : InMemoryPersistence,
  session_id : String,
  checkpoint : AgentCheckpoint,
) -> Unit {
  match self.by_session.get(session_id) {
    Some(cps) => cps.push(checkpoint)
    None => self.by_session[session_id] = [checkpoint]
  }
}

///|
fn InMemoryPersistence::list(
  self : InMemoryPersistence,
  session_id : String,
) -> Array[AgentCheckpoint] {
  match self.by_session.get(session_id) {
    Some(cps) => [..cps]
    None => []
  }
}

///|
fn InMemoryPersistence::latest(
  self : InMemoryPersistence,
  session_id : String,
) -> AgentCheckpoint? {
  guard self.by_session.get(session_id) is Some(cps) else { return None }
  guard cps.length() > 0 else { return None }
  let mut latest = cps[0]
  for cp in cps {
    // `>=` so that checkpoints sharing a timestamp resolve to the last saved, which is what
    // a caller with no clock (every stamp 0) means by "latest".
    if cp.created_at >= latest.created_at {
      latest = cp
    }
  }
  Some(latest)
}

///|
/// Save `checkpoint` under `session_id`.
pub fn InMemoryPersistence::save_checkpoint(
  self : InMemoryPersistence,
  session_id : String,
  checkpoint : AgentCheckpoint,
) -> Unit {
  self.put(session_id, checkpoint)
}

///|
/// Every checkpoint saved for `session_id`, in save order.
pub fn InMemoryPersistence::get_checkpoints(
  self : InMemoryPersistence,
  session_id : String,
) -> Array[AgentCheckpoint] {
  self.list(session_id)
}

///|
/// The most recent checkpoint for `session_id` — the highest `created_at`, ties going to the
/// last saved — or `None` when the session has none.
pub fn InMemoryPersistence::get_latest_checkpoint(
  self : InMemoryPersistence,
  session_id : String,
) -> AgentCheckpoint? {
  self.latest(session_id)
}

///|
pub impl PersistenceStorageProvider for InMemoryPersistence with fn save_checkpoint(
  self,
  session_id,
  checkpoint,
) {
  self.put(session_id, checkpoint)
}

///|
pub impl PersistenceStorageProvider for InMemoryPersistence with fn get_checkpoints(
  self,
  session_id,
) {
  self.list(session_id)
}

///|
pub impl PersistenceStorageProvider for InMemoryPersistence with fn get_latest_checkpoint(
  self,
  session_id,
) {
  self.latest(session_id)
}

///|
pub extend AgentCheckpoint with Debug::{to_repr}

///|
pub extend AgentCheckpoint with Eq::{not_equal, equal}
