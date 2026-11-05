// The node kinds whose client capability already existed but had no way into the graph:
// a multiple-choice request with a selector, a moderation check, a streamed request, and
// a schema-constrained request.

///|
/// A schema that only insists on an integer `n` — enough to tell a parsed reply from a
/// malformed one without a whole model type.
fn count_schema() -> @agent.StructuredSchema[Json] {
  {
    name: "Count",
    description: "an object with an integer n",
    schema: @tools.TObject(
      properties=[
        { name: "n", description: "the count", ptype: @tools.TInteger, },
      ],
      required=["n"],
    ),
    parse: j => {
      match j {
        Object(m) =>
          match m.get("n") {
            Some(Number(_, ..)) => Some(j)
            _ => None
          }
        _ => None
      }
    },
  }
}

///|
/// The selector sees all three candidates, so it can name the third. A node that had asked
/// for one completion would leave it nothing to choose from and answer with the first.
async test "a multiple-choice node asks for every candidate and the selector picks one" {
  @async.with_task_group(_g => {
    let judge = @agent.MockClient::new([@prompt.Message::assistant("I pick 2")])
    let selector : &@agent.ChoiceSelectionStrategy = @agent.LLMChoiceSelector::new(
      judge, @llm.deepseek_v4_flash,
    )
    let strat = @agent.AIAgentStrategy::new("best_of_three")
      .node("choose", @agent.NodeLLMRequestMultiple(selector, choices=3))
      .edge(@agent.start_node, "choose")
      .edge("choose", @agent.finish_node, condition=@agent.OnAssistantMessage)
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("answer A"),
      @prompt.Message::assistant("answer B"),
      @prompt.Message::assistant("answer C"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.run_strategy(strat, "which?") catch {
      e => fail(e.to_string())
    }
    assert_eq(out, "answer C")
  })
}

///|
async test "a moderation node reaches the client's moderate and carries the verdict" {
  @async.with_task_group(_g => {
    let strat = @agent.AIAgentStrategy::new("guard")
      .node("check", @agent.NodeModerate)
      .edge(@agent.start_node, "check")
      .edge("check", @agent.finish_node)
    let lenient = @agent.AIAgent::new(
      @agent.MockClient::new([]),
      model=@llm.deepseek_v4_flash,
    )
    let safe = lenient.run_strategy(strat, "hello") catch {
      e => fail(e.to_string())
    }
    assert_eq(safe, "safe")
    let strict = @agent.AIAgent::new(
      FlaggingClient::{ },
      model=@llm.deepseek_v4_flash,
    )
    let flagged = strict.run_strategy(strat, "hello") catch {
      e => fail(e.to_string())
    }
    assert_eq(flagged, "harmful")
  })
}

///|
/// The chunks are the proof: a node that had called the plain `execute` would still answer
/// correctly and leave the sink empty.
async test "a streaming node reaches execute_streaming and hands out the chunks" {
  @async.with_task_group(_g => {
    let chunks : Array[String] = []
    let strat = @agent.AIAgentStrategy::new("streamed")
      .node("stream", @agent.NodeLLMRequestStreaming(c => chunks.push(c)))
      .edge(@agent.start_node, "stream")
      .edge("stream", @agent.finish_node, condition=@agent.OnAssistantMessage)
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("hello world"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.run_strategy(strat, "hi") catch { e => fail(e.to_string()) }
    assert_eq(chunks, ["hello world"])
    assert_eq(out, "hello world")
  })
}

///|
async test "a structured node parses the reply and carries the JSON on" {
  @async.with_task_group(_g => {
    let seen : Array[@agent.NodeValue] = []
    let strat = @agent.AIAgentStrategy::new("shaped")
      .node("shape", @agent.NodeLLMRequestStructured(count_schema(), fixes=2))
      .custom_node("sink", (_s, v) => {
        seen.push(v)
        v
      })
      .edge(@agent.start_node, "shape")
      .edge("shape", "sink")
      .edge("sink", @agent.finish_node)
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("here you go: {\"n\": 233}"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.run_strategy(strat, "how many?") catch {
      e => fail(e.to_string())
    }
    assert_eq(seen.length(), 1)
    assert_eq(seen[0] == @agent.VJson({ "n": 233 }), true)
    assert_eq(out.contains("233"), true)
  })
}

///|
async test "a structured node re-asks a malformed reply within its fix budget" {
  @async.with_task_group(_g => {
    let strat = @agent.AIAgentStrategy::new("shaped_retry")
      .node("shape", @agent.NodeLLMRequestStructured(count_schema(), fixes=1))
      .edge(@agent.start_node, "shape")
      .edge("shape", @agent.finish_node)
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("sorry, no"),
      @prompt.Message::assistant("{\"n\": 66666}"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let out = agent.run_strategy(strat, "how many?") catch {
      e => fail(e.to_string())
    }
    assert_eq(out.contains("66666"), true)
  })
}

///|
async test "a structured node raises once its fix budget is spent" {
  @async.with_task_group(_g => {
    let strat = @agent.AIAgentStrategy::new("shaped_hopeless")
      .node("shape", @agent.NodeLLMRequestStructured(count_schema(), fixes=1))
      .edge(@agent.start_node, "shape")
      .edge("shape", @agent.finish_node)
    let mock = @agent.MockClient::new([
      @prompt.Message::assistant("nope"),
      @prompt.Message::assistant("still nope"),
    ])
    let agent = @agent.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
    let msg = try {
      agent.run_strategy(strat, "how many?") |> ignore
      "NO RAISE"
    } catch {
      @agent.AgentError(m) => m
      _ => "unexpected error kind"
    }
    assert_eq(
      msg.contains("no valid structured response after 2 attempts"),
      true,
    )
  })
}
