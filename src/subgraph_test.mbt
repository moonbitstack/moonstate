// Subgraphs (Koog `subgraph` / `SubgraphWithRetry`): a whole strategy nests as one node,
// walked against the same run — same conversation, same budgets — and a retrying one
// re-runs it until its predicate accepts the result.

///|
async test "a subgraph runs its own graph and its finish value returns into the parent" {
  @async.with_task_group(_g => {
    let visited : Array[String] = []
    let inner = @agent.AIAgentStrategy::new("inner")
      .custom_node("shout", (_s, v) => {
        visited.push("inner.shout")
        @agent.VText(v.text() + "!")
      })
      .edge(@agent.start_node, "shout")
      .edge("shout", @agent.finish_node)
    let outer = @agent.AIAgentStrategy::new("outer")
      .subgraph("inner", inner)
      .custom_node("wrap", (_s, v) => {
        visited.push("outer.wrap")
        @agent.VText("<" + v.text() + ">")
      })
      .edge(@agent.start_node, "inner")
      .edge("inner", "wrap")
      .edge("wrap", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(outer, "qwq") catch {
      e => fail(e.to_string())
    }
    assert_eq(visited, ["inner.shout", "outer.wrap"])
    assert_eq(out, "<qwq!>")
  })
}

///|
/// A subgraph is not a fresh run: what it says stays in the conversation the parent goes
/// on with, which is what makes "reason in a subgraph, then answer" work at all.
async test "a subgraph shares the run's conversation with its parent" {
  @async.with_task_group(_g => {
    let asked : Array[String] = []
    let events = @agent.EventHandler::new().on_llm_call_starting(p => {
      asked.push(p.messages.fold(init="", (acc, m) => acc + m.text_content()))
    })
    let inner = @agent.AIAgentStrategy::new("note")
      .custom_node("say", (s, _v) => {
        s.append_user("from-inner")
        @agent.VUnit
      })
      .edge(@agent.start_node, "say")
      .edge("say", @agent.finish_node)
    let outer = @agent.AIAgentStrategy::new("note_then_ask")
      .subgraph("note", inner)
      .custom_node("ask", (s, _v) => @agent.VReply(s.request_llm()))
      .edge(@agent.start_node, "note")
      .edge("note", "ask")
      .edge("ask", @agent.finish_node)
    let mock = @agent.MockClient::new([@prompt.Message::assistant("noted")])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash, events~)
    let out = agent.run_strategy(outer, "hhh") catch {
      e => fail(e.to_string())
    }
    assert_eq(asked, ["from-inner"])
    assert_eq(out, "noted")
  })
}

///|
async test "a retrying subgraph re-runs while the predicate rejects its result" {
  @async.with_task_group(_g => {
    let tries : Array[Int32] = []
    let inner = @agent.AIAgentStrategy::new("attempt")
      .custom_node("try", (_s, _v) => {
        tries.push(tries.length() + 1)
        @agent.VText(tries.length().to_string())
      })
      .edge(@agent.start_node, "try")
      .edge("try", @agent.finish_node)
    let outer = @agent.AIAgentStrategy::new("until_third")
      .subgraph_retry(
        "attempt",
        inner,
        until=v => v.text() == "3",
        max_retries=5,
      )
      .edge(@agent.start_node, "attempt")
      .edge("attempt", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(outer, "go") catch { e => fail(e.to_string()) }
    assert_eq(tries, [1, 2, 3])
    assert_eq(out, "3")
  })
}

///|
/// The retry budget is a bound, not a promise: when nothing satisfies the predicate the
/// last attempt's value is what flows on, so the graph can route on it.
async test "a retrying subgraph stops at max_retries and carries the last attempt out" {
  @async.with_task_group(_g => {
    let tries : Array[Int32] = []
    let inner = @agent.AIAgentStrategy::new("attempt")
      .custom_node("try", (_s, _v) => {
        tries.push(tries.length() + 1)
        @agent.VText(tries.length().to_string())
      })
      .edge(@agent.start_node, "try")
      .edge("try", @agent.finish_node)
    let outer = @agent.AIAgentStrategy::new("never_happy")
      .subgraph_retry("attempt", inner, until=_v => false, max_retries=2)
      .edge(@agent.start_node, "attempt")
      .edge("attempt", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(outer, "go") catch { e => fail(e.to_string()) }
    assert_eq(tries, [1, 2, 3])
    assert_eq(out, "3")
  })
}
