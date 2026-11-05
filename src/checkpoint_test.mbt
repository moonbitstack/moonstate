// The strategy graph's per-run storage and its node-boundary checkpointing: what a custom node
// can carry between nodes, and what a run resumed from a checkpoint picks up.

///|
/// A value a custom node parks in the run's storage — proof the store is not integers-only.
struct Plan {
  goal : String
  steps : Array[String]
} derive(Eq, Debug, ToJson, FromJson)

///|
/// A three-node graph: `plan` writes, `recall` reads back, `report` finishes on what it read.
fn planning_strategy(seen : Array[Plan]) -> @agent.AIAgentStrategy {
  @agent.AIAgentStrategy::new("planning")
  .custom_node("plan", (s, v) => {
    s.set("plan", { goal: v.text(), steps: ["look", "answer"], })
    s.set("ratio", 0.5)
    v
  })
  .custom_node("recall", (s, v) => {
    guard (s.get("plan") : Plan?) is Some(plan) else {
      return @agent.VText("no plan")
    }
    seen.push(plan)
    let _ = v
    @agent.VText(plan.goal + ": " + plan.steps.join(" -> "))
  })
  .edge(@agent.start_node, "plan")
  .edge("plan", "recall")
  .edge("recall", @agent.finish_node)
}

///|
async test "node storage: a custom node stores and reads back a non-integer value" {
  @async.with_task_group(_g => {
    let seen : Array[Plan] = []
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(planning_strategy(seen), "find the answer") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "find the answer: look -> answer")
    assert_eq(seen.length(), 1)
    assert_eq(seen[0], { goal: "find the answer", steps: ["look", "answer"], })
  })
}

///|
async test "node storage: a value read at the wrong type is absent, not a crash" {
  @async.with_task_group(_g => {
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let strategy = @agent.AIAgentStrategy::new("mistyped")
      .custom_node("write", (s, v) => {
        s.set("plan", { goal: "g", steps: [], })
        v
      })
      .custom_node("read", (s, _v) => {
        @agent.VText(
          ((s.get("plan") : Int32?) is Some(_)).to_string() +
          "/" +
          s.storage().contains("plan").to_string(),
        )
      })
      .edge(@agent.start_node, "write")
      .edge("write", "read")
      .edge("read", @agent.finish_node)
    let out = agent.run_strategy(strategy, "x") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "false/true")
  })
}

///|
/// A graph that counts its visits in storage and gives up on the third, so a test can stop a
/// run in the middle and resume it.
fn counting_strategy(
  fail_at~ : Int32,
  visits~ : Array[String],
) -> @agent.AIAgentStrategy {
  @agent.AIAgentStrategy::new("counting")
  .custom_node("one", (s, v) => {
    visits.push("one")
    s.set("n", (s.get("n") : Int32?).unwrap_or(0) + 1)
    v
  })
  .custom_node("two", (s, v) => {
    visits.push("two")
    let n = (s.get("n") : Int32?).unwrap_or(0)
    if n >= fail_at {
      return @agent.VText("stopped at " + n.to_string())
    }
    let _ = v
    @agent.VText("two saw " + n.to_string())
  })
  .custom_node("three", (s, _v) => {
    visits.push("three")
    @agent.VText("done with " + (s.get("n") : Int32?).unwrap_or(0).to_string())
  })
  .edge(@agent.start_node, "one")
  .edge("one", "two")
  .edge("two", "three")
  .edge("three", @agent.finish_node)
}

///|
async test "checkpointing: a run snapshots every node boundary" {
  @async.with_task_group(_g => {
    let store = InMemoryPersistence::new()
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(
      counting_strategy(fail_at=99, visits=[]),
      "go",
      checkpoints=@agent.Checkpointer::new(store, session="s1"),
    ) catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "done with 1")
    let cps = store.get_checkpoints("s1")
    // Start, one, two, three, finish — snapshotted before each node runs.
    assert_eq(cps.map(cp => cp.node_id), [
      "__start__", "one", "two", "three", "__finish__",
    ])
    // Storage is carried, and reflects the writes made before that node.
    let at_three = cps[3]
    let restored = @agent.AgentStorage::new()
    restored.restore(at_three.storage)
    assert_eq((restored.get("n") : Int32?), Some(1))
    assert_eq(at_three.last_input, Some(@agent.VText("two saw 1").to_json()))
  })
}

///|
/// A checkpoint is a point-in-time value, not a window onto the live run: the one taken before
/// the first node was taken when the store was empty, and nothing the run writes afterwards may
/// appear in it. This is a regression — the storage snapshot used to hand the checkpoint the
/// run's own map, so an early checkpoint read back the run's final state.
async test "checkpointing: a checkpoint taken before a write does not see it" {
  @async.with_task_group(_g => {
    let store = InMemoryPersistence::new()
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let strategy = @agent.AIAgentStrategy::new("late_write")
      .custom_node("write", (s, v) => {
        s.set("n", 233)
        v
      })
      .edge(@agent.start_node, "write")
      .edge("write", @agent.finish_node)
    let _ = agent.run_strategy(
      strategy,
      "go",
      checkpoints=@agent.Checkpointer::new(store, session="s1"),
    ) catch {
      e => fail(e.to_string())
    }
    let cps = store.get_checkpoints("s1")
    assert_eq(cps.map(cp => cp.node_id), ["__start__", "write", "__finish__"])
    let read_n = (cp : AgentCheckpoint) => {
      let restored = @agent.AgentStorage::new()
      restored.restore(cp.storage)
      (restored.get("n") : Int32?)
    }
    // Before the write, twice: an empty store both times. Only the boundary after it sees 233.
    assert_eq(read_n(cps[0]), None)
    assert_eq(read_n(cps[1]), None)
    assert_eq(read_n(cps[2]), Some(233))
  })
}

///|
/// The same guarantee one level down: a snapshot is a value, so writing to the store afterwards
/// cannot reach back into what was already taken.
test "node storage: a snapshot is a copy, not a window onto the store" {
  let store = @agent.AgentStorage::new()
  let empty = store.snapshot()
  store.set("n", 233)
  let one = store.snapshot()
  store.set("n", 66666)
  assert_eq(empty, Json::object(Map([])))
  assert_eq(one, { "n": 233 })
}

///|
async test "checkpointing: a resumed run continues at the right node" {
  @async.with_task_group(_g => {
    let store = InMemoryPersistence::new()
    let first_visits = []
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let _ = agent.run_strategy(
      counting_strategy(fail_at=99, visits=first_visits),
      "go",
      checkpoints=@agent.Checkpointer::new(store, session="s1"),
    ) catch {
      e => fail(e.to_string())
    }
    assert_eq(first_visits, ["one", "two", "three"])

    // Resume from the snapshot taken before "three": only "three" runs again, and it sees the
    // storage the first run had written.
    let resumed_visits = []
    let taken = store.get_checkpoints("s1")
    assert_eq(taken.length(), 5)
    let at_three = taken[3]
    assert_eq(at_three.node_id, "three")
    let out = agent.run_strategy(
      counting_strategy(fail_at=99, visits=resumed_visits),
      "ignored on resume",
      resume_from=at_three,
    ) catch {
      e => fail(e.to_string())
    }
    assert_eq(resumed_visits, ["three"])
    assert_eq(out, "done with 1")
  })
}

///|
async test "checkpointing: resuming replays the conversation and the spent iterations" {
  @async.with_task_group(_g => {
    let store = InMemoryPersistence::new()
    let client = RecordingClient::new([
      @prompt.Message::assistant("first"),
      @prompt.Message::assistant("second"),
    ])
    let agent = @agent.AIAgent::new(
      client,
      model=@llm.deepseek_v4_flash,
      system_prompt="be brief",
      max_iterations=2,
    )
    let strategy = @agent.AIAgentStrategy::new("two_calls")
      .node("first", @agent.NodeLLMRequest)
      .node("second", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "first")
      .edge("first", "second")
      .edge("second", @agent.finish_node)
    let _ = agent.run_strategy(
      strategy,
      "hi",
      checkpoints=@agent.Checkpointer::new(store, session="s1"),
    ) catch {
      e => fail(e.to_string())
    }
    // The snapshot before "second" holds the system prompt, the first exchange, and the one
    // LLM call already spent.
    let taken = store.get_checkpoints("s1")
    assert_eq(taken.length(), 4)
    let at_second = taken[2]
    assert_eq(at_second.node_id, "second")
    assert_eq(at_second.agent_iterations, 1)
    assert_eq(at_second.message_history.map(m => m.text_content()), [
      "be brief", "hi",
    ])
    assert_eq(at_second.llm_model, Some(@llm.deepseek_v4_flash))

    // Resuming re-runs "second" on that conversation: the budget already has one call on it,
    // so the resumed run may make exactly one more.
    let second_client = RecordingClient::new([
      @prompt.Message::assistant("resumed"),
    ])
    let resumed = @agent.AIAgent::new(
      second_client,
      model=@llm.deepseek_v4_flash,
      max_iterations=2,
    )
    let out = resumed.run_strategy(strategy, "hi", resume_from=at_second) catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "resumed")
    // What it actually sent: the replayed conversation, then the value the checkpoint was
    // carrying — not the `input` argument, which a resume ignores.
    assert_eq(second_client.last().messages.map(m => m.text_content()), [
      "be brief", "hi", "first",
    ])
  })
}

///|
async test "checkpointing: a resume past the iteration budget is refused" {
  @async.with_task_group(_g => {
    let agent = @agent.AIAgent::new(
      RecordingClient::new([@prompt.Message::assistant("nope")]),
      model=@llm.deepseek_v4_flash,
      max_iterations=2,
    )
    let strategy = @agent.AIAgentStrategy::new("one_call")
      .node("call", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "call")
      .edge("call", @agent.finish_node)
    let spent = AgentCheckpoint::new(
      checkpoint_id="cp",
      created_at=0L,
      node_id="call",
      message_history=[@prompt.Message::user("hi")],
      last_input=@agent.VText("hi").to_json(),
      agent_iterations=2,
    )
    let message = try {
      agent.run_strategy(strategy, "hi", resume_from=spent) |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentError(m) => m
      e => "unexpected: " + e.to_string()
    }
    assert_eq(message.contains("max iterations".view()), true)
  })
}

///|
test "checkpointing: a node value round-trips through Json" {
  let values = [
    @agent.VText("hi"),
    @agent.VJson({ "a": 1 }),
    @agent.VUnit,
    @agent.VReply(@prompt.Message::assistant("reply")),
    @agent.VModeration(@agent.ModerationResult::safe()),
  ]
  for value in values {
    let back = @agent.NodeValue::from_json(value.to_json()) catch {
      @agent.AgentError(m) => fail(m)
      @agent.AgentStopped(m) => fail(m)
    }
    assert_eq(back, value)
  }
}

///|
test "checkpointing: a value that is not a node value is refused, not guessed at" {
  let bad = [
    Json::string("plain"),
    { "kind": "wat" },
    { "kind": "text", "value": 233 },
  ]
  for json in bad {
    let raised = try {
      @agent.NodeValue::from_json(json) |> ignore
      false
    } catch {
      @agent.AgentError(_) => true
      _ => false
    }
    assert_eq(raised, true)
  }
}

///|
async test "checkpointing: snapshots are numbered and stamped in order" {
  @async.with_task_group(_g => {
    let store = InMemoryPersistence::new()
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let _ = agent.run_strategy(
      counting_strategy(fail_at=99, visits=[]),
      "go",
      checkpoints=@agent.Checkpointer::new(store, session="s1"),
    ) catch {
      e => fail(e.to_string())
    }
    let cps = store.get_checkpoints("s1")
    assert_eq(cps.map(cp => cp.checkpoint_id), [
      "cp-0", "cp-1", "cp-2", "cp-3", "cp-4",
    ])
    // Without a clock the stamp is the sequence number, so the last boundary is the latest.
    assert_eq(cps.map(cp => cp.created_at), [0L, 1L, 2L, 3L, 4L])
    assert_eq(
      store.get_latest_checkpoint("s1").map(cp => cp.node_id),
      Some("__finish__"),
    )
  })
}

///|
async test "checkpointing: a supplied clock stamps the snapshots" {
  @async.with_task_group(_g => {
    let store = InMemoryPersistence::new()
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let mut tick = 100L
    let _ = agent.run_strategy(
      counting_strategy(fail_at=99, visits=[]),
      "go",
      checkpoints=@agent.Checkpointer::new(store, session="s1", clock=() => {
        tick = tick + 10L
        tick
      }),
    ) catch {
      e => fail(e.to_string())
    }
    assert_eq(store.get_checkpoints("s1").map(cp => cp.created_at), [
      110L, 120L, 130L, 140L, 150L,
    ])
  })
}

///|
async test "node storage: parallel branches inherit the store but write to their own" {
  @async.with_task_group(_g => {
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let strategy = @agent.AIAgentStrategy::new("branching")
      .custom_node("seed", (s, v) => {
        s.set("plan", { goal: "shared", steps: ["a"], })
        v
      })
      .custom_node("left", (s, _v) => {
        s.set("plan", { goal: "left-only", steps: [], })
        @agent.VText("L")
      })
      .custom_node("right", (s, _v) => {
        @agent.VText(
          "R:" + (s.get("plan") : Plan?).map(p => p.goal).unwrap_or("none"),
        )
      })
      .parallel("both", ["left", "right"], merge=vs => {
        @agent.VText(vs.map(v => v.text()).join("|"))
      })
      .custom_node("after", (s, v) => {
        @agent.VText(
          v.text() +
          " parent=" +
          (s.get("plan") : Plan?).map(p => p.goal).unwrap_or("none"),
        )
      })
      .edge(@agent.start_node, "seed")
      .edge("seed", "both")
      .edge("both", "after")
      .edge("after", @agent.finish_node)
    let out = agent.run_strategy(strategy, "go") catch {
      e => fail(e.to_string())
    }
    // Each branch saw what the parent had stored; neither overwrote the parent's copy.
    assert_eq(out, "L|R:shared parent=shared")
  })
}

///|
async test "checkpointing: a subgraph's own nodes are not checkpointed" {
  @async.with_task_group(_g => {
    let store = InMemoryPersistence::new()
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let inner = @agent.AIAgentStrategy::new("inner")
      .custom_node("inner_step", (_s, v) => @agent.VText("inner:" + v.text()))
      .edge(@agent.start_node, "inner_step")
      .edge("inner_step", @agent.finish_node)
    let outer = @agent.AIAgentStrategy::new("outer")
      .subgraph("nested", inner)
      .edge(@agent.start_node, "nested")
      .edge("nested", @agent.finish_node)
    let out = agent.run_strategy(
      outer,
      "go",
      checkpoints=@agent.Checkpointer::new(store, session="s1"),
    ) catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "inner:go")
    // Only the outer walk's boundaries: a node name means nothing outside the graph that
    // declares it, and a resume re-enters the top-level walk.
    assert_eq(store.get_checkpoints("s1").map(cp => cp.node_id), [
      "__start__", "nested", "__finish__",
    ])
  })
}
