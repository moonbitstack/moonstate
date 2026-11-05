///|
/// A checkpoint carrying a two-message history at a strategy node.
fn sample_checkpoint(id : String, at : Int64) -> AgentCheckpoint {
  AgentCheckpoint::new(
    checkpoint_id=id,
    created_at=at,
    node_id="llm_request",
    message_history=[
      @prompt.Message::user("hello"),
      @prompt.Message::assistant("hi there"),
    ],
    last_input=Json::string("hello"),
    agent_iterations=1,
  )
}

///|
test "save then list a session's checkpoints in order" {
  let store = InMemoryPersistence::new()
  store.save_checkpoint("s1", sample_checkpoint("c1", 100))
  store.save_checkpoint("s1", sample_checkpoint("c2", 200))
  let cps = store.get_checkpoints("s1")
  assert_eq(cps.length(), 2)
  assert_eq(cps[0].checkpoint_id, "c1")
  assert_eq(cps[1].checkpoint_id, "c2")
}

///|
test "the latest checkpoint is the most recently created" {
  let store = InMemoryPersistence::new()
  store.save_checkpoint("s1", sample_checkpoint("c1", 100))
  store.save_checkpoint("s1", sample_checkpoint("c2", 200))
  // Saved last but stamped earliest, so it is not the latest.
  store.save_checkpoint("s1", sample_checkpoint("c0", 50))
  let latest = store.get_latest_checkpoint("s1")
  assert_eq(latest.map(cp => cp.checkpoint_id), Some("c2"))
}

///|
test "a checkpoint restores its full message history" {
  let store = InMemoryPersistence::new()
  store.save_checkpoint("s1", sample_checkpoint("c1", 100))
  let restored = match store.get_latest_checkpoint("s1") {
    Some(cp) => cp
    None => abort("expected a checkpoint")
  }
  assert_eq(restored.message_history.length(), 2)
  assert_eq(restored.message_history[0].text_content(), "hello")
  assert_eq(restored.message_history[1].text_content(), "hi there")
  assert_eq(restored.node_id, "llm_request")
}

///|
test "checkpoints are isolated by session" {
  let store = InMemoryPersistence::new()
  store.save_checkpoint("s1", sample_checkpoint("c1", 100))
  assert_eq(store.get_checkpoints("s2").length(), 0)
  assert_eq(store.get_latest_checkpoint("s2"), None)
  assert_eq(store.get_checkpoints("s1").length(), 1)
}

///|
test "the trait seam sees the same store as the inherent methods" {
  let store = InMemoryPersistence::new()
  let provider : &PersistenceStorageProvider = store
  provider.save_checkpoint("s1", sample_checkpoint("c1", 100))
  store.save_checkpoint("s1", sample_checkpoint("c2", 200))
  assert_eq(provider.get_checkpoints("s1").length(), 2)
  assert_eq(
    provider.get_latest_checkpoint("s1").map(cp => cp.checkpoint_id),
    Some("c2"),
  )
}
