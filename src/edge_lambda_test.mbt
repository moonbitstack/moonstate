// Arbitrary edge conditions and transforms (Koog `onCondition { }` / `transformed { }`):
// an edge fires on any test of the value at all, and rewrites what the next node is given.

///|
async test "a predicate edge routes on the value it is handed" {
  @async.with_task_group(_g => {
    let strat = @agent.AIAgentStrategy::new("router")
      .custom_node("classify", (_s, v) => v)
      .custom_node("long", (_s, v) => @agent.VText(v.text() + " (long)"))
      .custom_node("short", (_s, v) => @agent.VText(v.text() + " (short)"))
      .edge(@agent.start_node, "classify")
      .edge(
        "classify",
        "long",
        condition=@agent.OnPredicate(v => v.text().length() > 3),
      )
      .edge("classify", "short")
      .edge("long", @agent.finish_node)
      .edge("short", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let wordy = agent.run_strategy(strat, "heke1228") catch {
      e => fail(e.to_string())
    }
    let terse = agent.run_strategy(strat, "qwq") catch {
      e => fail(e.to_string())
    }
    assert_eq(wordy, "heke1228 (long)")
    assert_eq(terse, "qwq (short)")
  })
}

///|
/// The transform is a function of the value, not a constant: it can read what the source
/// node produced and hand the next node something derived from it.
async test "an edge transform rewrites the value the next node sees" {
  @async.with_task_group(_g => {
    let seen : Array[String] = []
    let strat = @agent.AIAgentStrategy::new("rewrite")
      .custom_node("src", (_s, _v) => @agent.VText("raw"))
      .custom_node("sink", (_s, v) => {
        seen.push(v.text())
        v
      })
      .edge(@agent.start_node, "src")
      .edge("src", "sink", transform=v => @agent.VText("[" + v.text() + "]"))
      .edge("sink", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(strat, "ignored") catch {
      e => fail(e.to_string())
    }
    assert_eq(seen, ["[raw]"])
    assert_eq(out, "[raw]")
  })
}
