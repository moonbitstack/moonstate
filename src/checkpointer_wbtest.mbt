// Agent checkpointing (Koog `agents-features-snapshot`).

///|
test "persistence: save, list, latest-by-time, and storage snapshot round-trip" {
  // Snapshot an agent storage into a checkpoint.
  let storage = AgentStorage::new()
  storage.set("step", 3)
  storage.set("goal", "answer")
  let checkpoint : AgentCheckpoint = AgentCheckpoint::new(
    checkpoint_id="cp-1",
    created_at=1000L,
    node_id="call_llm",
    message_history=[@prompt.Message::user("hello")],
    storage=storage.snapshot(),
    agent_iterations=2,
  )
  let provider = InMemoryPersistence::new()
  provider.save_checkpoint("s1", checkpoint)
  // A later checkpoint at the same session.
  let checkpoint2 : AgentCheckpoint = {
    ..checkpoint,
    checkpoint_id: "cp-2",
    created_at: 2000L,
    node_id: "__finish__",
  }
  provider.save_checkpoint("s1", checkpoint2)
  assert_eq(provider.get_checkpoints("s1").length(), 2)
  assert_eq(provider.get_checkpoints("other").length(), 0)
  assert_eq(provider.get_latest_checkpoint("other") is None, true)
  // The latest checkpoint is the one with the highest created_at.
  guard provider.get_latest_checkpoint("s1") is Some(latest) else {
    fail("expected a latest checkpoint")
  }
  assert_eq(latest.checkpoint_id, "cp-2")
  assert_eq(latest.node_id, "__finish__")
  assert_eq(latest.agent_iterations, 2)
  // Restoring an agent storage from a checkpoint's snapshot recovers its typed values.
  let restored = AgentStorage::new()
  restored.restore(checkpoint.storage)
  assert_eq((restored.get("step") : Int32?), Some(3))
  assert_eq((restored.get("goal") : String?), Some("answer"))
  assert_eq(restored.size(), 2)
}
