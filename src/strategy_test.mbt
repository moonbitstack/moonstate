///|
/// Driving the full tool loop through the explicit `single_run_strategy` graph
/// gives the same result as `AIAgent.run`: the graph requests the LLM, executes
/// the `add` tool on the tool-call reply, feeds the result back, and finishes on
/// the plain-text reply. LoopClient answers from the conversation, so this proves
/// the whole wiring ran, not that a canned string came back.
async test "run_strategy with single_run_strategy runs the full tool loop" {
  @async.with_task_group(_g => {
    let registry = @tools.ToolRegistry::new().add(AddTool::{ })
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=registry,
      system_prompt="you can add",
    )
    let out = agent.run_strategy(@agent.single_run_strategy(), "what is 2+3?") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "The answer is 5")
  })
}

///|
/// A hand-wired strategy — start to a lone LLM node to finish — runs a plain
/// completion, showing the DSL builds arbitrary graphs, not just the canned loop.
async test "a custom strategy graph wires start -> llm -> finish" {
  @async.with_task_group(_g => {
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("direct answer"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let strategy = @agent.AIAgentStrategy::new("just_llm")
      .node("llm", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "llm")
      .edge("llm", @agent.finish_node, condition=@agent.OnAssistantMessage)
    let out = agent.run_strategy(strategy, "hi") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "direct answer")
  })
}

///|
/// When a node's output matches none of its outgoing edges, the run fails rather
/// than hanging: LoopClient's first reply requests a tool, but this graph offers
/// only an assistant-message edge out of the LLM node.
async test "run_strategy raises when no outgoing edge matches" {
  @async.with_task_group(_g => {
    let registry = @tools.ToolRegistry::new().add(AddTool::{ })
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
      tool_registry=registry,
    )
    let strategy = @agent.AIAgentStrategy::new("broken")
      .node("llm", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "llm")
      .edge("llm", @agent.finish_node, condition=@agent.OnAssistantMessage)
    let msg = try {
      agent.run_strategy(strategy, "2+3?") |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentError(m) => m
      _ => "unexpected error kind"
    }
    assert_eq(msg.contains("no edge out of"), true)
  })
}

///|
/// A run that is asked to stop finishes the node it is in and stops at the next
/// boundary, rather than being cut off mid-node: the custom node that calls `stop`
/// still returns its own value, that value comes back on `AgentStopped`, and the
/// node after it never runs.
async test "a stopped run finishes its current node and goes no further" {
  @async.with_task_group(_g => {
    let agent = @agent.AIAgent::new(
      LoopClient::{ },
      model=@llm.deepseek_v4_flash,
    )
    let handle = @agent.RunHandle::new()
    let visited : Array[String] = []
    let strategy = @agent.AIAgentStrategy::new("stoppable")
      .custom_node("halt", (_session, _v) => {
        visited.push("halt")
        handle.stop()
        @agent.VText("hhh")
      })
      .custom_node("after", (_session, v) => {
        visited.push("after")
        v
      })
      .edge(@agent.start_node, "halt")
      .edge("halt", "after")
      .edge("after", @agent.finish_node)
    let msg = try {
      agent.run_strategy(strategy, "qwq", stop=handle) |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentStopped(partial) => partial
      @agent.AgentError(m) => "wrong error: " + m
      _ => "unexpected error kind"
    }
    assert_eq(msg, "hhh")
    assert_eq(visited, ["halt"])
    assert_eq(handle.stopping(), true)
  })
}

///|
/// A tool that raises is reported as an error result, not as ordinary output. The
/// model reads `is_error` to decide whether to try again, so burying the failure in
/// the text would tell it the call succeeded.
test "a failing tool result carries is_error" {
  let ok = @prompt.Message::tool_result(tool="add", output="5")
  let bad = @prompt.Message::tool_result(
    tool="add",
    output="tool error: boom",
    is_error=true,
  )
  let flag = fn(m : @prompt.Message) -> Bool {
    match m.parts[0] {
      ToolResult(is_error~, ..) => is_error
      _ => false
    }
  }
  assert_eq(flag(ok), false)
  assert_eq(flag(bad), true)
}
