// The tool-specific edge condition (Koog `onToolCalls { tc -> tc.tool == "__exit__" }`): an
// edge fires when the reply calls a named tool, so a strategy can finish on an exit tool.

///|
async test "strategy: an edge routes to finish on a specific named tool call" {
  @async.with_task_group(_g => {
    let reply : @prompt.Message = {
      role: @prompt.Assistant,
      parts: [
        @prompt.Text("done via exit"),
        @prompt.ToolCall(id=Some("c1"), tool="__exit__", args={
          "result": "done",
        }),
      ],
      finish_reason: None,
      meta: None,
    }
    let mock = @agent.MockClient::new([reply])
    let strat = @agent.AIAgentStrategy::new("exit_test")
      .node("llm", @agent.NodeLLMRequest)
      .edge(@agent.start_node, "llm")
      .edge("llm", @agent.finish_node, condition=@agent.OnToolNamed("__exit__"))
      .edge("llm", @agent.finish_node, condition=@agent.OnAssistantMessage)
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.run_strategy(strat, "go") catch { e => fail(e.to_string()) }
    assert_eq(out, "done via exit")
  })
}
