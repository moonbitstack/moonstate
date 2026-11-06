///|
/// How many supersteps a run may take before it is stopped. This is the bound a
/// graph made of cycles relies on; it is LangGraph 1.2's default recursion limit
/// of 25 (`libs/langgraph/langgraph/constants.py`), kept the same so a graph
/// ported from there needs no new number.
pub let default_limit : Int32 = 25

///|
/// A compiled graph: the nodes, the edges between them, and the three services a
/// run leans on — a saver for checkpoints, a store for long-term memory, and an
/// executor for where the nodes run. Everything structural was checked in
/// `compile`, so a run only fails for reasons the run itself discovers.
pub struct Graph[S, U] {
  name : String
  merge : (S, U) -> S
  initial : S
  entry : String
  nodes : Map[String, NodeSpec[S, U]]
  edges : Map[String, Array[String]]
  joins : Array[(Array[String], String)]
  branches : Map[String, Array[async (S) -> Array[String]]]
  saver : &Saver?
  store : &Store?
  executor : &Executor
  limit : Int32
}

///|
pub fn[S, U] Graph::name(self : Graph[S, U]) -> String {
  self.name
}

///|
/// The superstep bound this graph was compiled with.
pub fn[S, U] Graph::limit(self : Graph[S, U]) -> Int32 {
  self.limit
}

///|
fn[S, U] Graph::successors(self : Graph[S, U], name : String) -> Array[String] {
  match self.edges.get(name) {
    Some(to) => to
    None => []
  }
}

///|
fn[S, U] Graph::routes_of(
  self : Graph[S, U],
  name : String,
) -> Array[async (S) -> Array[String]] {
  match self.branches.get(name) {
    Some(routes) => routes
    None => []
  }
}

///|
fn[S, U] Graph::retry_of(self : Graph[S, U], name : String) -> Retry? {
  match self.nodes.get(name) {
    Some(spec) => spec.retry
    None => None
  }
}

///|
fn[K, V] count_of(map : Map[K, V]) -> Int32 {
  let mut count = 0
  for _ in map {
    count = count + 1
  }
  count
}

///|
/// The nodes a run reaches from the entry over declared edges and joins. A
/// branch's targets are only known at run time, so a graph with any branch is
/// treated as reaching every node: the check refuses only what the structure
/// proves wrong, never a graph that would have run.
fn[S, U] Builder::reachable(self : Builder[S, U]) -> Array[String] {
  let seen = []
  let queue = [self.entry_name()]
  for name in self.routed {
    if !queue.contains(name) {
      queue.push(name)
    }
  }
  let mut open = false
  for branch in self.branches {
    let (_, _) = branch
    open = true
  }
  let mut cursor = 0
  while cursor < queue.length() {
    let name = queue[cursor]
    cursor = cursor + 1
    if seen.contains(name) {
      continue
    }
    seen.push(name)
    for from_to in self.edges {
      let (from, to) = from_to
      if from == name && !queue.contains(to) {
        queue.push(to)
      }
    }
    for join in self.joins {
      let (from, to) = join
      if from.contains(name) && !queue.contains(to) {
        queue.push(to)
      }
    }
    if open {
      for other, _ in self.nodes {
        if !queue.contains(other) {
          queue.push(other)
        }
      }
    }
  }
  seen
}

///|
/// Whether a node has nothing declared after it: where a run can end. A branch
/// counts as leaving the node, since its route is only known at run time.
fn[S, U] Builder::is_terminal(self : Builder[S, U], name : String) -> Bool {
  for from_to in self.edges {
    let (from, _) = from_to
    if from == name {
      return false
    }
  }
  for join in self.joins {
    let (from, _) = join
    if from.contains(name) {
      return false
    }
  }
  for branch in self.branches {
    let (from, _) = branch
    if from == name {
      return false
    }
  }
  true
}

///|
/// The node a run starts at: the declared one, or the only node of a single-node
/// graph.
fn[S, U] Builder::entry_name(self : Builder[S, U]) -> String {
  match self.entry {
    Some(name) => name
    None =>
      if count_of(self.nodes) == 1 {
        match self.nodes.keys().next() {
          Some(only) => only
          None => ""
        }
      } else {
        ""
      }
  }
}

///|
fn[S, U] Builder::check(self : Builder[S, U]) -> Unit raise Refused {
  if count_of(self.nodes) == 0 {
    raise Refused::NoNodes
  }
  for name in self.duplicates {
    raise Refused::DuplicateNode(node=name)
  }
  let entry = self.entry_name()
  if entry == "" {
    raise Refused::NoEntry
  }
  if !self.nodes.contains(entry) {
    raise Refused::UnknownEntry(node=entry)
  }
  for from_to in self.edges {
    let (from, to) = from_to
    if !self.nodes.contains(from) || !self.nodes.contains(to) {
      raise Refused::DanglingEdge(from~, to~)
    }
  }
  for join in self.joins {
    let (from, to) = join
    if !self.nodes.contains(to) {
      raise Refused::DanglingEdge(from="join", to~)
    }
    for name in from {
      if !self.nodes.contains(name) {
        raise Refused::DanglingEdge(from=name, to~)
      }
    }
  }
  for branch in self.branches {
    let (from, _) = branch
    if !self.nodes.contains(from) {
      raise Refused::DanglingEdge(from~, to="<branch>")
    }
  }
  let seen = self.reachable()
  for name, _ in self.nodes {
    if !seen.contains(name) {
      raise Refused::Unreachable(node=name)
    }
  }
  let mut ends = false
  for name, _ in self.nodes {
    if self.is_terminal(name) {
      ends = true
    }
  }
  if !ends {
    raise Refused::NoExit
  }
}

///|
fn push_unique(list : Array[String], value : String) -> Unit {
  if !list.contains(value) {
    list.push(value)
  }
}

///|
/// Fold the collected structure into a graph, refusing a definition that cannot
/// run: an edge to nowhere, a node nothing reaches, a graph with no end.
pub fn[S, U] Builder::compile(
  self : Builder[S, U],
  name : String,
  saver? : &Saver,
  store? : &Store,
  executor? : &Executor,
  limit? : Int32,
) -> Graph[S, U] raise Refused {
  self.check()
  let entry = self.entry_name()
  if entry == "" {
    raise Refused::NoEntry
  }
  let adjacency : Map[String, Array[String]] = Map([])
  for from_to in self.edges {
    let (from, to) = from_to
    match adjacency.get(from) {
      Some(successors) => push_unique(successors, to)
      None => adjacency[from] = [to]
    }
  }
  let routes : Map[String, Array[async (S) -> Array[String]]] = Map([])
  for branch in self.branches {
    let (from, route) = branch
    match routes.get(from) {
      Some(list) => list.push(route)
      None => routes[from] = [route]
    }
  }
  {
    name,
    merge: self.merge,
    initial: self.initial,
    entry,
    nodes: self.nodes,
    edges: adjacency,
    joins: self.joins,
    branches: routes,
    saver,
    store,
    executor: match executor {
      Some(executor) => executor
      None => inline
    },
    limit: match limit {
      Some(limit) => limit
      None => default_limit
    },
  }
}
