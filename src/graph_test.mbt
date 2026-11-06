///|
/// Compile the graph and hand back the refusal, or fail the test if it compiled.
fn refusal_of(
  builder : @moonstate.Builder[Counter, Patch],
) -> @moonstate.Refused? {
  let refused : @moonstate.Refused? = try {
    let _ = builder.compile("bad")
    None
  } catch {
    refused => Some(refused)
  }
  refused
}

///|
test "an empty builder is refused" {
  let refused = refusal_of(counter_builder())
  match refused {
    Some(@moonstate.NoNodes) => ()
    _ => fail("expected NoNodes")
  }
}

///|
test "a graph of several nodes without an entry is refused" {
  let builder = counter_builder()
    .node("a", (_state, _run) => [])
    .node("b", (_state, _run) => [])
    .edge("a", "b")
  match refusal_of(builder) {
    Some(@moonstate.NoEntry) => ()
    _ => fail("expected NoEntry")
  }
}

///|
test "an entry naming an undefined node is refused" {
  let builder = counter_builder()
    .entry("nowhere")
    .node("a", (_state, _run) => [])
  match refusal_of(builder) {
    Some(@moonstate.UnknownEntry(node~)) => assert_eq(node, "nowhere")
    _ => fail("expected UnknownEntry")
  }
}

///|
test "an edge to an undefined node is refused" {
  let builder = counter_builder()
    .entry("a")
    .node("a", (_state, _run) => [])
    .edge("a", "ghost")
  match refusal_of(builder) {
    Some(@moonstate.DanglingEdge(from~, to~)) => {
      assert_eq(from, "a")
      assert_eq(to, "ghost")
    }
    _ => fail("expected DanglingEdge")
  }
}

///|
test "a node nothing reaches is refused" {
  let builder = counter_builder()
    .entry("a")
    .node("a", (_state, _run) => [])
    .node("orphan", (_state, _run) => [])
  match refusal_of(builder) {
    Some(@moonstate.Unreachable(node~)) => assert_eq(node, "orphan")
    _ => fail("expected Unreachable")
  }
}

///|
test "a graph whose every node has a successor is refused" {
  let builder = counter_builder()
    .entry("a")
    .node("a", (_state, _run) => [])
    .node("b", (_state, _run) => [])
    .edge("a", "b")
    .edge("b", "a")
  match refusal_of(builder) {
    Some(@moonstate.NoExit) => ()
    _ => fail("expected NoExit")
  }
}

///|
test "adding the same node name twice is refused" {
  let builder = counter_builder()
    .entry("a")
    .node("a", (_state, _run) => [])
    .node("a", (_state, _run) => [])
  match refusal_of(builder) {
    Some(@moonstate.DuplicateNode(node~)) => assert_eq(node, "a")
    _ => fail("expected DuplicateNode")
  }
}

///|
test "a single node graph needs no explicit entry" {
  let builder = counter_builder().node("only", (_state, _run) => [])
  let graph = builder.compile("single") catch {
    refused => abort("refused: " + (refused : Error).to_string())
  }
  assert_eq(graph.limit(), @moonstate.default_limit)
}
