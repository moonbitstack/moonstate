///|
fn show_int(x : Int32?) -> String {
  match x {
    Some(n) => n.to_string()
    None => "none"
  }
}

///|
/// The three-node strategy the resume half of this example walks. Each node appends its own
/// name to `visited`, so a resumed run can be seen to skip what it already did.
fn trail_strategy(visited : Array[String]) -> @moonstate.AIAgentStrategy {
  @moonstate.AIAgentStrategy::new("trail")
  .custom_node("gather", (s, v) => {
    visited.push("gather")
    s.set("found", ["fact-1", "fact-2"])
    v
  })
  .custom_node("summarize", (s, v) => {
    visited.push("summarize")
    let _ = v
    let found : Array[String] = (s.get("found") : Array[String]?).unwrap_or([])
    @moonstate.VText("summary of " + found.join(", "))
  })
  .edge(@moonstate.start_node, "gather")
  .edge("gather", "summarize")
  .edge("summarize", @moonstate.finish_node)
}

///|
/// Agent state and checkpointing (Koog `AIAgentStorage` + persistence): typed values
/// go into a JSON-backed `AgentStorage` and come back at the type requested at the
/// call site; a snapshot round-trips through JSON. A full `AgentCheckpoint` — the
/// message history, model, tools, and storage at a strategy node — is then saved to
/// an `InMemoryPersistence` and read back, latest-first. Finally a real run is
/// checkpointed at every node boundary and resumed from the middle of the graph.
///
///     moon run examples/19-agent-checkpoint --target native
#coverage.skip
async fn main {
  // Typed key/value storage backed by Json.
  let store = @moonstate.AgentStorage::new()
  store.set("count", 233)
  store.set("name", "heke1228")
  store.set("ratio", 0.5)
  println("count as Int: " + show_int(store.get("count")))
  println("name absent as Int: " + show_int(store.get("name")))
  println("size=\{store.size()} contains(name)=\{store.contains("name")}")
  let _ = store.remove("ratio")
  println("after remove(ratio): size=\{store.size()}")
  let snap = store.snapshot()
  println("snapshot: " + snap.stringify())

  // A fresh store restored from that snapshot holds the same values.
  let restored = @moonstate.AgentStorage::new()
  restored.restore(snap)
  println("restored count: " + show_int(restored.get("count")))

  // A checkpoint of a whole agent run, persisted and read back.
  let persistence = @moonstate.InMemoryPersistence::new()
  let checkpoint : @moonstate.AgentCheckpoint = @moonstate.AgentCheckpoint::new(
    checkpoint_id="cp-233",
    created_at=233L,
    node_id="send_tool_result",
    message_history=[
      @prompt.Message::user("what is 2 + 3?"),
      @prompt.Message::assistant("the answer is 5"),
    ],
    llm_params=@prompt.LLMParams::default(),
    llm_model=@llm.deepseek_v4_flash,
    tools=["add"],
    storage=snap,
    last_input=Json::string("the answer is 5"),
    agent_iterations=2,
  )
  persistence.save_checkpoint("session-qwq", checkpoint)
  persistence.save_checkpoint("session-qwq", {
    ..checkpoint,
    checkpoint_id: "cp-234",
    created_at: 234L,
    node_id: "__finish__",
  })
  let all = persistence.get_checkpoints("session-qwq")
  println("session-qwq has \{all.length()} checkpoint(s)")
  match persistence.get_latest_checkpoint("session-qwq") {
    Some(cp) =>
      println(
        "latest: " +
        cp.checkpoint_id +
        " at node " +
        cp.node_id +
        ", history=\{cp.message_history.length()} msgs, iterations=\{cp.agent_iterations}",
      )
    None => println("no checkpoint")
  }

  // A run that checkpoints itself, then one resumed from the middle of that graph.
  @async.with_task_group(_g => {
    let agent = @moonstate.AIAgent::new(
      @moonstate.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let sessions = @moonstate.InMemoryPersistence::new()
    let first = []
    let out = agent.run_strategy(
      trail_strategy(first),
      "what happened?",
      checkpoints=@moonstate.Checkpointer::new(sessions, session="run-233"),
    ) catch {
      e => "failed: " + e.to_string()
    }
    println("full run visited " + first.join(", ") + " -> " + out)
    let taken = sessions.get_checkpoints("run-233")
    println("checkpoints at: " + taken.map(cp => cp.node_id).join(", "))

    // Resume from the snapshot taken before `summarize`: `gather` does not run again, and its
    // storage comes back with the checkpoint.
    let again = []
    let resumed = agent.run_strategy(
      trail_strategy(again),
      "unused on resume",
      resume_from=taken[2],
    ) catch {
      e => "failed: " + e.to_string()
    }
    println("resumed run visited " + again.join(", ") + " -> " + resumed)
  })
}
