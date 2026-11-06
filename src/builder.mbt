///|
/// One node as the builder collected it: what to run, and how often to try.
struct NodeSpec[S, U] {
  run : async (S, Run) -> Array[Step[S, U]]
  retry : Retry?
}

///|
/// Accumulates nodes and edges, then checks them once in `compile`. Every method
/// returns the builder, so a graph reads as one chain.
pub struct Builder[S, U] {
  merge : (S, U) -> S
  initial : S
  mut entry : String?
  nodes : Map[String, NodeSpec[S, U]]
  edges : Array[(String, String)]
  joins : Array[(Array[String], String)]
  branches : Array[(String, async (S) -> Array[String])]
  routed : Array[String]
  duplicates : Array[String]
}

///|
/// A builder whose state starts at `initial` and whose every merged write goes
/// through `merge`. `initial` is what a run starts from before the input is
/// merged in, so it is the empty state: zeroed counters, empty lists.
pub fn[S, U] Builder::new(merge~ : (S, U) -> S, initial~ : S) -> Builder[S, U] {
  {
    merge,
    initial,
    entry: None,
    nodes: Map([]),
    edges: [],
    joins: [],
    branches: [],
    routed: [],
    duplicates: [],
  }
}

///|
/// Add node `name`. `run` gets the state and a `Run` handle and returns the steps
/// it wants applied; `retry` gives it more than one try.
pub fn[S, U] Builder::node(
  self : Builder[S, U],
  name : String,
  run : async (S, Run) -> Array[Step[S, U]],
  retry? : Retry,
) -> Builder[S, U] {
  if self.nodes.contains(name) {
    self.duplicates.push(name)
  }
  self.nodes[name] = { run, retry, }
  self
}

///|
/// Run `to` after `from`, unconditionally.
pub fn[S, U] Builder::edge(
  self : Builder[S, U],
  from : String,
  to : String,
) -> Builder[S, U] {
  self.edges.push((from, to))
  self
}

///|
/// Run `to` once every node in `from` has run in the same superstep, and not
/// before: a join is a gate, not just an edge.
pub fn[S, U] Builder::join(
  self : Builder[S, U],
  from : Array[String],
  to : String,
) -> Builder[S, U] {
  self.joins.push((from, to))
  self
}

///|
/// Let `route` decide where to go after `from`. It is called with the state as
/// merged at the end of the superstep, so it sees what the nodes wrote.
pub fn[S, U] Builder::branch(
  self : Builder[S, U],
  from : String,
  route : async (S) -> Array[String],
) -> Builder[S, U] {
  self.branches.push((from, route))
  self
}

///|
/// Declare that `name` is entered at run time — by a `Goto`, a `Send` or a route —
/// rather than by an edge. Without this the compile-time reachability check has
/// no way to tell such a node from dead code, and refuses the graph.
pub fn[S, U] Builder::routed(
  self : Builder[S, U],
  name : String,
) -> Builder[S, U] {
  self.routed.push(name)
  self
}

///|
/// Make `name` the node a run starts at. Without it a graph of exactly one node
/// starts there, and anything larger is refused.
pub fn[S, U] Builder::entry(
  self : Builder[S, U],
  name : String,
) -> Builder[S, U] {
  self.entry = Some(name)
  self
}

///|
/// Run a whole compiled graph as one node of this one: `enter` reads the child's
/// input out of the parent's state, `leave` folds the child's result back into
/// the parent's update.
pub fn[
  T : @json.ToJson + @json.FromJson,
  V : @json.ToJson + @json.FromJson,
  S,
  U,
] Builder::subgraph(
  self : Builder[S, U],
  name : String,
  graph : Graph[T, V],
  enter~ : (S) -> T,
  leave~ : (T) -> U,
) -> Builder[S, U] {
  let run = async fn(state : S, run : Run) -> Array[Step[S, U]] {
    let thread = run.thread() + "|" + name + "@" + run.checkpoint()
    let out = graph.run_nested(enter(state), thread, run.saver())
    [Write(leave(out))]
  }
  self.node(name, run)
}
