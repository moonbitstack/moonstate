///|
/// A tool the chat strategy runs before the model calls the exit tool.
struct Greet {}

///|
impl @tools.Tool for Greet with fn descriptor(_self) {
  {
    name: "greet",
    description: "greet someone",
    required_parameters: [],
    optional_parameters: [],
  }
}

///|
impl @tools.Tool for Greet with fn execute_raw(_self, _args) {
  "greetings"
}

///|
fn agent_over(
  msgs : Array[@prompt.Message],
  registry? : @tools.ToolRegistry,
) -> @moonstate.AIAgent {
  let mock = @moonstate.MockClient::new(msgs)
  match registry {
    Some(r) =>
      @moonstate.AIAgent::new(mock, model=@llm.deepseek_v4_flash, tool_registry=r)
    None => @moonstate.AIAgent::new(mock, model=@llm.deepseek_v4_flash)
  }
}

///|
/// The strategy graph the agent loop is one wiring of (Koog's strategy DSL): nodes
/// are `NodeKind`s or `custom_node` handlers over a `NodeSession`, edges fire on an
/// `EdgeCondition`. Shown: the prebuilt `single_run` / `chat` / `react` strategies,
/// a hand-wired start→llm→finish graph, and a custom-node graph that seeds a user
/// turn and requests the model. Each runs against a scripted client, deterministic.
///
///     moon run examples/08-strategy-graph --target native
#coverage.skip
async fn main {
  @async.with_task_group(_g => {
    // single_run: the plain-text path finishes on the first assistant message.
    let a1 = agent_over([@prompt.Message::assistant("quick answer")])
    println(
      "single_run: " +
      (a1.run_strategy(@moonstate.single_run_strategy(), "hi") catch {
        e => e.to_string()
      }),
    )

    // A hand-wired graph: start -> one LLM node -> finish.
    let strategy = @moonstate.AIAgentStrategy::new("just_llm")
      .node("llm", @moonstate.NodeLLMRequest)
      .edge(@moonstate.start_node, "llm")
      .edge("llm", @moonstate.finish_node, condition=@moonstate.OnAssistantMessage)
    let a2 = agent_over([@prompt.Message::assistant("direct answer")])
    println(
      "hand_wired: " +
      (a2.run_strategy(strategy, "hi") catch { e => e.to_string() }),
    )

    // A custom node: append the input as a user turn, then request a tools-off reply.
    let custom = @moonstate.AIAgentStrategy::new("echoish")
      .custom_node("ask", (s, v) => {
        s.append_user(v.text())
        @moonstate.VReply(s.request_llm_no_tools())
      })
      .edge(@moonstate.start_node, "ask")
      .edge("ask", @moonstate.finish_node, condition=@moonstate.OnAssistantMessage)
    let a3 = agent_over([@prompt.Message::assistant("thought it over")])
    println(
      "custom_node: " +
      (a3.run_strategy(custom, "ponder this") catch { e => e.to_string() }),
    )

    // react: reason (tools-off) then act; a plain-text action finishes.
    let a4 = agent_over([
      @prompt.Message::assistant("let me reason"),
      @prompt.Message::assistant("the answer is 42"),
    ])
    println(
      "react: " +
      (a4.run_strategy(@moonstate.react_strategy(), "solve x") catch {
        e => e.to_string()
      }),
    )

    // chat: a tool call runs, then the exit tool ends the chat with the transform.
    let plain = @prompt.Message::assistant("thinking out loud")
    let call : @prompt.Message = {
      role: @prompt.Assistant,
      parts: [@prompt.ToolCall(id=Some("c1"), tool="greet", args={})],
      finish_reason: None,
      meta: None,
    }
    let exit : @prompt.Message = {
      role: @prompt.Assistant,
      parts: [
        @prompt.ToolCall(id=Some("c2"), tool="__exit__", args={
          "result": "bye",
        }),
      ],
      finish_reason: None,
      meta: None,
    }
    let a5 = agent_over(
      [plain, call, exit],
      registry=@tools.ToolRegistry::new().add(Greet::{ }),
    )
    println(
      "chat: " +
      (a5.run_strategy(@moonstate.chat_agent_strategy(), "hello") catch {
        e => e.to_string()
      }),
    )
  })
}
