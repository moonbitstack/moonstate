///|
fn checkpoint(
  id : String,
  at : Int64,
  input : String,
) -> @moonstate.AgentCheckpoint {
  @moonstate.AgentCheckpoint::new(
    checkpoint_id=id,
    created_at=at,
    node_id="llm_request",
    message_history=[
      @prompt.Message::user(input),
      @prompt.Message::assistant("acknowledged: " + input),
    ],
    last_input=Json::string(input),
    agent_iterations=1,
  )
}

///|
/// Checkpoint persistence (Koog `agents-features-snapshot`): an agent run's message
/// history and position are stored per session as `AgentCheckpoint`s through the
/// `PersistenceStorageProvider` seam, then listed in order or read latest-first to
/// resume. Sessions are isolated. The in-memory provider ships for tests.
///
///     moon run examples/21-persistence --target native
#coverage.skip
fn main {
  let store = @moonstate.InMemoryPersistence::new()
  store.save_checkpoint("s1", checkpoint("c1", 100L, "hello"))
  store.save_checkpoint("s1", checkpoint("c2", 200L, "again"))
  let cps = store.get_checkpoints("s1")
  println("s1 has \{cps.length()} checkpoint(s), in save order:")
  for cp in cps {
    println(
      "  " + cp.checkpoint_id + " history=\{cp.message_history.length()} msgs",
    )
  }
  match store.get_latest_checkpoint("s1") {
    Some(cp) => {
      println("latest is " + cp.checkpoint_id)
      println("  restored history:")
      for m in cp.message_history {
        println("    " + m.text_content())
      }
    }
    None => println("no checkpoint")
  }

  // A second session is a separate, empty history.
  println("s2 checkpoints: \{store.get_checkpoints("s2").length()}")
}
