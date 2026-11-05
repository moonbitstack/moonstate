// The parallel node (Koog `parallel`): several of the strategy's nodes run at once on the
// same input, each on a forked conversation, and one merge folds every result into the
// value that flows on.

///|
async test "a parallel node runs every branch and the merge sees every result" {
  @async.with_task_group(_g => {
    let ran : Array[String] = []
    let strat = @agent.AIAgentStrategy::new("fan_out")
      .custom_node("a", (_s, v) => {
        ran.push("a")
        @agent.VText(v.text() + "-a")
      })
      .custom_node("b", (_s, v) => {
        ran.push("b")
        @agent.VText(v.text() + "-b")
      })
      .custom_node("c", (_s, v) => {
        ran.push("c")
        @agent.VText(v.text() + "-c")
      })
      .parallel("fan", ["a", "b", "c"], merge=vs => {
        @agent.VText(
          vs.fold(init="", (acc, v) => {
            if acc == "" {
              v.text()
            } else {
              acc + "|" + v.text()
            }
          }),
        )
      })
      .edge(@agent.start_node, "fan")
      .edge("fan", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(strat, "qwq") catch {
      e => fail(e.to_string())
    }
    assert_eq(ran, ["a", "b", "c"])
    assert_eq(out, "qwq-a|qwq-b|qwq-c")
  })
}

///|
/// The branches really are in flight together: the one that waits is started first and
/// finishes last, and the merge is still handed the results in the order the node named
/// them. Run one after another, `slow` would finish first.
async test "parallel branches interleave, and the merge still sees declaration order" {
  @async.with_task_group(_g => {
    let finished : Array[String] = []
    let strat = @agent.AIAgentStrategy::new("interleaved")
      .custom_node("slow", (_s, _v) => {
        @async.sleep(30)
        finished.push("slow")
        @agent.VText("slow")
      })
      .custom_node("quick", (_s, _v) => {
        finished.push("quick")
        @agent.VText("quick")
      })
      .parallel("both", ["slow", "quick"], merge=vs => {
        @agent.VText(vs.fold(init="", (acc, v) => acc + v.text()))
      })
      .edge(@agent.start_node, "both")
      .edge("both", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let out = agent.run_strategy(strat, "go") catch { e => fail(e.to_string()) }
    assert_eq(finished, ["quick", "slow"])
    assert_eq(out, "slowquick")
  })
}

///|
/// Branches fork the conversation, so one branch's turn never lands in another's request.
/// Sharing one prompt would make the second request carry both turns.
async test "parallel branches run on forked conversations" {
  @async.with_task_group(_g => {
    let asked : Array[Int32] = []
    let events = @agent.EventHandler::new().on_llm_call_starting(p => {
      asked.push(p.messages.length())
    })
    let strat = @agent.AIAgentStrategy::new("forked")
      .custom_node("left", (s, _v) => {
        s.append_user("left")
        @agent.VReply(s.request_llm())
      })
      .custom_node("right", (s, _v) => {
        s.append_user("right")
        @agent.VReply(s.request_llm())
      })
      .parallel("both", ["left", "right"], merge=vs => {
        @agent.VText(vs.length().to_string())
      })
      .edge(@agent.start_node, "both")
      .edge("both", @agent.finish_node)
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("l"),
      @prompt.Message::assistant("r"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash, events~)
    let out = agent.run_strategy(strat, "hhh") catch {
      e => fail(e.to_string())
    }
    assert_eq(asked, [1, 1])
    assert_eq(out, "2")
  })
}

///|
/// A branch that names a node the strategy does not have fails the run, rather than
/// quietly merging one result short.
async test "a parallel node whose branch names an unknown node fails the run" {
  @async.with_task_group(_g => {
    let strat = @agent.AIAgentStrategy::new("typo")
      .custom_node("here", (_s, v) => v)
      .parallel("both", ["here", "ther"], merge=vs => vs[0])
      .edge(@agent.start_node, "both")
      .edge("both", @agent.finish_node)
    let agent = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let msg = try {
      agent.run_strategy(strat, "go") |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentError(m) => m
      _ => "unexpected error kind"
    }
    assert_eq(msg, "parallel branch names no node 'ther'")
  })
}

///|
/// Forking the conversation must not fork the iteration cap: two branches calling the
/// model spend two of the agent's calls, not one each.
async test "parallel branches spend the one run budget between them" {
  @async.with_task_group(_g => {
    let strat = @agent.AIAgentStrategy::new("two_calls")
      .node("left", @agent.NodeLLMRequest)
      .node("right", @agent.NodeLLMRequest)
      .parallel("both", ["left", "right"], merge=vs => vs[0])
      .edge(@agent.start_node, "both")
      .edge("both", @agent.finish_node)
    let scripted = () => {
      [@prompt.Message::assistant("l"), @prompt.Message::assistant("r")]
    }
    let roomy = @agent.AIAgent::new(
      @agent.MockClient::new(scripted()),
      model=@llm.deepseek_v4_flash,
      max_iterations=2,
    )
    let out = roomy.run_strategy(strat, "go") catch { e => fail(e.to_string()) }
    assert_eq(out, "l")
    let tight = @agent.AIAgent::new(
      @agent.MockClient::new(scripted()),
      model=@llm.deepseek_v4_flash,
      max_iterations=1,
    )
    let msg = try {
      tight.run_strategy(strat, "go") |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentError(m) => m
      _ => "unexpected error kind"
    }
    assert_eq(msg.contains("max iterations (1) exceeded"), true)
  })
}
