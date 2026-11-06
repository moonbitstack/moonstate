///|
/// One task of a superstep, with its input state already decoded.
priv struct Queued[S] {
  node : String
  input : S?
}

///|
/// The engine's working copy of a thread: where the state is, what is queued for
/// the next superstep, and which checkpoint that superstep's writes belong to.
priv struct Session[S, U] {
  graph : Graph[S, U]
  thread : String
  on : async (Event[S, U]) -> Unit
  executor : &Executor
  saver : &Saver?
  merge : (S, U) -> S
  limit : Int32
  mut state : S
  mut pending : Array[Queued[S]]
  mut step : Int32
  mut seq : Int32
  mut current : String
  mut parent : String?
  resumed : Bool
  answer : Json?
  mut replay : Map[String, Array[Json]]
  mut customs : Map[String, Array[Json]]
  replay_writes : Array[TaskWrite]
  cancelled : Ref[Bool]
}

///|
/// Every call that leaves the engine — a saver, a store, an executor, a stream
/// callback — raises the untyped `Error`. One boundary turns those into
/// `GraphError` so a caller can match on what happened.
async fn save(saver : &Saver, checkpoint : Checkpoint) -> Unit raise GraphError {
  saver.put(checkpoint) catch {
    error => raise GraphError::Backend(reason="saver: " + error_text(error))
  }
}

///|
async fn note_writes(
  saver : &Saver,
  thread : String,
  id : String,
  task : String,
  values : Array[Json],
) -> Unit raise GraphError {
  saver.put_writes(thread, id, task, values) catch {
    error => raise GraphError::Backend(reason="saver: " + error_text(error))
  }
}

///|
async fn load_latest(
  saver : &Saver,
  thread : String,
) -> Checkpoint? raise GraphError {
  saver.get(thread) catch {
    error => raise GraphError::Backend(reason="saver: " + error_text(error))
  }
}

///|
async fn load_history(
  saver : &Saver,
  thread : String,
  limit? : Int32,
) -> Array[Checkpoint] raise GraphError {
  saver.list(thread, limit?) catch {
    error => raise GraphError::Backend(reason="saver: " + error_text(error))
  }
}

///|
async fn execute(
  executor : &Executor,
  works : Array[Work],
) -> Array[Done] raise GraphError {
  executor.each(works) catch {
    error => raise GraphError::Backend(reason="executor: " + error_text(error))
  }
}

///|
async fn[S, U] report(
  on : async (Event[S, U]) -> Unit,
  event : Event[S, U],
) -> Unit raise GraphError {
  on(event) catch {
    error => raise GraphError::Backend(reason="stream: " + error_text(error))
  }
}

///|
async fn[S] route_from(
  route : async (S) -> Array[String],
  state : S,
) -> Array[String] raise GraphError {
  route(state) catch {
    error => raise GraphError::Backend(reason="branch: " + error_text(error))
  }
}

///|
/// Wait between retries. `@async.sleep` is non-raising on the native backend and
/// raising elsewhere, so it is called through a raising function type to keep one
/// call site for all four targets.
async fn pause(ms : Int32) -> Unit raise GraphError {
  let sleeper : async (Int32) -> Unit = ms => @async.sleep(ms)
  sleeper(ms) catch {
    error =>
      raise GraphError::Backend(reason="retry delay: " + error_text(error))
  }
}

///|
fn pad6(n : Int32) -> String {
  let text = n.to_string()
  let zeros = StringBuilder()
  for i = text.length(); i < 6; i = i + 1 {
    zeros.write_char('0')
  }
  zeros.to_string() + text
}

///|
/// A task's identity inside its superstep. The position, not a counter, because
/// a resumed superstep has to line its pending tasks up with the writes that
/// were recorded for them.
fn task_key(step : Int32, index : Int32, node : String) -> String {
  step.to_string() + ":" + index.to_string() + ":" + node
}

///|
fn writes_map(writes : Array[TaskWrite]) -> Map[String, Array[Json]] {
  let map : Map[String, Array[Json]] = Map([])
  for write in writes {
    map[write.task] = write.values
  }
  map
}

///|
fn[S : @json.ToJson, U] Session::checkpoint(
  self : Session[S, U],
  id : String,
  seq : Int32,
  interrupt : Json?,
) -> Checkpoint {
  let pending : Array[Pending] = []
  for task in self.pending {
    pending.push({
      node: task.node,
      input: match task.input {
        Some(state) => Some(@json.to_json(state))
        None => None
      },
    })
  }
  {
    thread: self.thread,
    id,
    parent: self.parent,
    seq,
    step: self.step,
    state: @json.to_json(self.state),
    pending,
    interrupt,
    created_at: @env.now().reinterpret_as_int64(),
    writes: None,
  }
}

///|
fn[S : @json.ToJson, U : @json.ToJson] Session::work(
  self : Session[S, U],
  index : Int32,
  attempt : Int32,
) -> Work {
  let task = self.pending[index]
  let spec = self.graph.nodes.get(task.node).unwrap()
  let input = match task.input {
    Some(state) => state
    None => self.state
  }
  let key = task_key(self.step, index, task.node)
  let buffer = match self.customs.get(key) {
    Some(buffer) => buffer
    None => {
      let buffer : Array[Json] = []
      self.customs[key] = buffer
      buffer
    }
  }
  let run = {
    thread: self.thread,
    step: self.step,
    checkpoint: self.current,
    answer: self.answer,
    store: self.graph.store,
    saver: self.saver,
    cancelled: self.cancelled,
    emit: fn(value) { buffer.push(value) },
    writes: self.replay_writes,
  }
  {
    graph: self.graph.name,
    node: task.node,
    thread: self.thread,
    step: self.step,
    attempt,
    input: fn() { @json.to_json(input) },
    run: async fn() {
      let steps = (spec.run)(input, run)
      steps.map(step => step.encode())
    },
  }
}

///|
fn[S, U] asks_to_stop(steps : Array[Step[S, U]]) -> Bool {
  for step in steps {
    match step {
      Interrupt(_) => return true
      _ => ()
    }
  }
  false
}

///|
fn[S] push_planned(next : Array[Queued[S]], node : String) -> Unit {
  for task in next {
    if task.node == node && task.input is None {
      return
    }
  }
  next.push({ node, input: None, })
}

///|
fn[S] has_planned(next : Array[Queued[S]], node : String) -> Bool {
  for task in next {
    if task.node == node {
      return true
    }
  }
  false
}

///|
/// Run the thread until no task is queued. Each turn of the loop is one
/// superstep: persist where we are, run the queued tasks, merge what they wrote
/// in task order, and work out who runs next.
async fn[S : @json.ToJson + @json.FromJson, U : @json.ToJson + @json.FromJson] drive(
  sess : Session[S, U],
) -> S raise GraphError {
  let mut fresh_superstep = !sess.resumed
  while sess.pending.length() > 0 {
    if sess.cancelled.val {
      raise GraphError::Cancelled(thread=sess.thread)
    }
    if sess.step >= sess.limit {
      raise GraphError::StepLimit(limit=sess.limit)
    }
    if fresh_superstep {
      let id = "cp-" + pad6(sess.seq)
      let checkpoint = sess.checkpoint(id, sess.seq, None)
      sess.current = id
      sess.seq = sess.seq + 1
      match sess.saver {
        Some(saver) => save(saver, checkpoint)
        None => ()
      }
    }
    let id = sess.current
    for task in sess.pending {
      report(sess.on, Started(node=task.node))
    }
    let todo : Array[Int32] = []
    for index = 0; index < sess.pending.length(); index = index + 1 {
      let key = task_key(sess.step, index, sess.pending[index].node)
      if !sess.replay.contains(key) {
        todo.push(index)
      }
    }
    let steps_of : Map[String, Array[Step[S, U]]] = Map([])
    let mut attempt : Int32 = 0
    let mut remaining = todo
    while remaining.length() > 0 {
      let works : Array[Work] = []
      for index in remaining {
        works.push(sess.work(index, attempt))
      }
      let done = execute(sess.executor, works)
      if done.length() != remaining.length() {
        raise GraphError::Backend(
          reason="executor returned " +
            done.length().to_string() +
            " results for " +
            remaining.length().to_string() +
            " tasks",
        )
      }
      let again : Array[Int32] = []
      for at = 0; at < remaining.length(); at = at + 1 {
        let index = remaining[at]
        let result = done[at]
        match result.error {
          Some(message) => {
            let attempts = match sess.graph.retry_of(sess.pending[index].node) {
              Some(retry) => retry.attempts
              None => 1
            }
            if attempt + 1 >= attempts {
              raise GraphError::NodeFailed(
                node=sess.pending[index].node,
                message~,
              )
            }
            again.push(index)
          }
          None => {
            // A task that finished is filed before the rest of the batch is
            // judged, so a neighbour's failure does not cost its work.
            let key = task_key(sess.step, index, sess.pending[index].node)
            let raw = result.values.unwrap_or([])
            sess.replay[key] = raw
            steps_of[key] = decode_steps(raw)
            match sess.saver {
              Some(saver) =>
                // A task that asked to stop is not filed: it has to run again
                // when the thread resumes, not replay its interrupt.
                if !asks_to_stop(steps_of[key]) {
                  note_writes(saver, sess.thread, id, key, raw)
                }
              None => ()
            }
          }
        }
      }
      attempt = attempt + 1
      if again.length() > 0 {
        match sess.graph.retry_of(sess.pending[again[0]].node) {
          Some(retry) => if retry.delay > 0 { pause(retry.delay) }
          None => ()
        }
      }
      remaining = again
    }
    // Tasks replayed from the checkpoint carry their steps in `sess.replay`
    // already; only the ones that just ran were decoded above.
    for index = 0; index < sess.pending.length(); index = index + 1 {
      let key = task_key(sess.step, index, sess.pending[index].node)
      if !steps_of.contains(key) {
        steps_of[key] = decode_steps(sess.replay.get(key).unwrap_or([]))
      }
    }
    let mut state = sess.state
    let next : Array[Queued[S]] = []
    let commanded : Array[String] = []
    let mut interrupt : Json? = None
    let mut stopped_at = 0
    let mut halted = false
    for index = 0; index < sess.pending.length(); index = index + 1 {
      let task = sess.pending[index]
      let key = task_key(sess.step, index, task.node)
      let steps = steps_of[key]
      let mut cut = false
      for step in steps {
        match step {
          Write(update) => {
            state = (sess.merge)(state, update)
            report(sess.on, Updates(node=task.node, update))
          }
          Goto(to) => {
            push_unique(commanded, task.node)
            push_planned(next, to)
          }
          Send(to, input) => {
            push_unique(commanded, task.node)
            next.push({ node: to, input: Some(input), })
          }
          Interrupt(value) => {
            interrupt = Some(value)
            cut = true
          }
        }
        if cut {
          break
        }
      }
      if cut {
        stopped_at = index
        halted = true
        break
      }
      match sess.customs.get(key) {
        Some(buffer) =>
          for value in buffer {
            report(sess.on, Custom(node=task.node, value))
          }
        None => ()
      }
      report(sess.on, Finished(node=task.node))
    }
    if halted {
      // The run stops before the next superstep. Everything the interrupting
      // task and the ones behind it produced is dropped, so resuming re-runs
      // them from the same input rather than from half-applied writes.
      sess.state = state
      let rest : Array[Queued[S]] = []
      for index = stopped_at; index < sess.pending.length(); index = index + 1 {
        rest.push(sess.pending[index])
      }
      sess.pending = rest
      sess.parent = Some(id)
      let value = interrupt.unwrap_or(Json::null())
      // The superstep's own checkpoint is replaced rather than added to: one
      // checkpoint per superstep, and this one now carries the question the
      // thread is waiting on.
      let checkpoint = sess.checkpoint(id, sess.seq - 1, Some(value))
      match sess.saver {
        Some(saver) => save(saver, checkpoint)
        None => ()
      }
      report(sess.on, Interrupted(value))
      raise GraphError::Interrupted(thread=sess.thread, value~)
    }
    let triggered : Array[String] = []
    for task in sess.pending {
      push_unique(triggered, task.node)
    }
    let planned : Array[String] = []
    for name in triggered {
      if commanded.contains(name) {
        // A node that named its own successor is not also followed through the
        // edges it declared: the command is the whole routing decision.
        continue
      }
      for to in sess.graph.successors(name) {
        push_unique(planned, to)
      }
      for route in sess.graph.routes_of(name) {
        for to in route_from(route, state) {
          push_unique(planned, to)
        }
      }
    }
    for join in sess.graph.joins {
      let (from, to) = join
      let mut ready = true
      for name in from {
        if !triggered.contains(name) {
          ready = false
        }
      }
      if ready {
        push_unique(planned, to)
      } else {
        let kept : Array[String] = []
        for name in planned {
          if name != to {
            kept.push(name)
          }
        }
        planned.clear()
        for name in kept {
          planned.push(name)
        }
      }
    }
    let pending : Array[Queued[S]] = []
    for task in next {
      if task.input is Some(_) || !has_planned(pending, task.node) {
        pending.push(task)
      }
    }
    for name in planned {
      if !has_planned(pending, name) {
        pending.push({ node: name, input: None, })
      }
    }
    sess.state = state
    sess.pending = pending
    sess.step = sess.step + 1
    sess.parent = Some(id)
    sess.replay = Map([])
    sess.customs = Map([])
    fresh_superstep = true
    report(sess.on, Values(state))
  }
  // The run has nowhere left to go, so the state it ends on is worth a
  // checkpoint of its own: without it `state` would report the state the last
  // superstep started from, still naming the node it already ran.
  match sess.saver {
    Some(saver) => {
      let id = "cp-" + pad6(sess.seq)
      let checkpoint = sess.checkpoint(id, sess.seq, None)
      sess.seq = sess.seq + 1
      save(saver, checkpoint)
    }
    None => ()
  }
  sess.state
}

///|
fn[S : @json.FromJson, U] Graph::decode(
  _self : Graph[S, U],
  json : Json,
) -> S raise GraphError {
  @json.from_json(json) catch {
    error =>
      raise GraphError::Unreadable(
        reason="checkpoint state: " + error_text(error),
      )
  }
}

///|
async fn[S, U] Graph::latest(
  self : Graph[S, U],
  thread : String,
) -> Checkpoint? raise GraphError {
  match self.saver {
    Some(saver) => load_latest(saver, thread)
    None => None
  }
}

///|
fn[S, U] Graph::fresh(
  self : Graph[S, U],
  thread : String,
  state : S,
  on : async (Event[S, U]) -> Unit,
) -> Session[S, U] {
  {
    graph: self,
    thread,
    on,
    executor: self.executor,
    saver: self.saver,
    merge: self.merge,
    limit: self.limit,
    state,
    pending: [{ node: self.entry, input: None, }],
    step: 0,
    seq: 0,
    current: "",
    parent: None,
    resumed: false,
    answer: None,
    replay: Map([]),
    customs: Map([]),
    replay_writes: [],
    cancelled: Ref(false),
  }
}

///|
fn[S, U] Graph::reopen(
  self : Graph[S, U],
  thread : String,
  checkpoint : Checkpoint,
  on : async (Event[S, U]) -> Unit,
  answer : Json?,
  decode : (Json) -> S raise GraphError,
) -> Session[S, U] raise GraphError {
  let pending : Array[Queued[S]] = []
  for task in checkpoint.pending {
    pending.push({
      node: task.node,
      input: match task.input {
        Some(json) => Some(decode(json))
        None => None
      },
    })
  }
  let writes = checkpoint.writes.unwrap_or([])
  {
    graph: self,
    thread,
    on,
    executor: self.executor,
    saver: self.saver,
    merge: self.merge,
    limit: self.limit,
    state: decode(checkpoint.state),
    pending,
    step: checkpoint.step,
    seq: checkpoint.seq + 1,
    current: checkpoint.id,
    parent: Some(checkpoint.id),
    resumed: true,
    answer,
    replay: writes_map(writes),
    customs: Map([]),
    replay_writes: writes,
    cancelled: Ref(false),
  }
}

///|
async fn[S : @json.FromJson, U] Graph::open(
  self : Graph[S, U],
  thread : String,
  input : U?,
  on : async (Event[S, U]) -> Unit,
) -> Session[S, U] raise GraphError {
  match self.latest(thread) {
    Some(checkpoint) =>
      if checkpoint.pending.length() > 0 {
        // A crashed run picks up where its last checkpoint left it: the input was
        // merged in before that checkpoint was written, so it is not applied twice.
        self.reopen(thread, checkpoint, on, None, json => self.decode(json))
      } else {
        let state = match input {
          Some(update) => (self.merge)(self.decode(checkpoint.state), update)
          None => self.decode(checkpoint.state)
        }
        let carried = {
          thread: checkpoint.thread,
          id: checkpoint.id,
          parent: checkpoint.parent,
          seq: checkpoint.seq,
          step: checkpoint.step,
          state: checkpoint.state,
          pending: [{ node: self.entry, input: None, }],
          interrupt: checkpoint.interrupt,
          created_at: checkpoint.created_at,
          writes: checkpoint.writes,
        }
        let session = self.reopen(thread, carried, on, None, json => {
          self.decode(json)
        })
        { ..session, state, step: 0, resumed: false, }
      }
    None => {
      let state = match input {
        Some(update) => (self.merge)(self.initial, update)
        None => self.initial
      }
      self.fresh(thread, state, on)
    }
  }
}

///|
/// Run `input` through the graph under `thread` and return the final state.
///
/// A thread with a checkpoint continues from it: a run that crashed is picked up
/// at its last superstep, and one that finished starts a new turn. Checkpoints
/// are written only when the graph was compiled with a saver; without one the
/// run is still superstep-based, it just has nothing to come back to.
pub async fn[
  S : @json.ToJson + @json.FromJson,
  U : @json.ToJson + @json.FromJson,
] Graph::run(
  self : Graph[S, U],
  input : U,
  thread? : String,
) -> S raise GraphError {
  self.stream(input, _ => (), thread?)
}

///|
/// `run`, with every event reported to `on` as it happens.
pub async fn[
  S : @json.ToJson + @json.FromJson,
  U : @json.ToJson + @json.FromJson,
] Graph::stream(
  self : Graph[S, U],
  input : U,
  on : async (Event[S, U]) -> Unit,
  thread? : String,
) -> S raise GraphError {
  let thread = thread.unwrap_or("default")
  let session = self.open(thread, Some(input), on)
  drive(session)
}

///|
/// Continue a thread that stopped at an interrupt, handing the waiting node
/// `answer` through `Run::answer`.
pub async fn[
  S : @json.ToJson + @json.FromJson,
  U : @json.ToJson + @json.FromJson,
] Graph::resume_with(
  self : Graph[S, U],
  thread : String,
  answer : Json,
) -> S raise GraphError {
  self.resume_stream(thread, answer, _ => ())
}

///|
/// `resume_with`, with every event of the continued run reported to `on`.
pub async fn[
  S : @json.ToJson + @json.FromJson,
  U : @json.ToJson + @json.FromJson,
] Graph::resume_stream(
  self : Graph[S, U],
  thread : String,
  answer : Json,
  on : async (Event[S, U]) -> Unit,
) -> S raise GraphError {
  let checkpoint = match self.latest(thread) {
    Some(checkpoint) => checkpoint
    None => raise GraphError::MissingThread(thread~)
  }
  if checkpoint.pending.length() == 0 {
    raise GraphError::NotInterrupted(thread~)
  }
  let session = self.reopen(thread, checkpoint, on, Some(answer), json => {
    self.decode(json)
  })
  drive(session)
}

///|
/// The thread as it stands, or `None` when it has no checkpoint.
pub async fn[S : @json.FromJson, U] Graph::state(
  self : Graph[S, U],
  thread : String,
) -> Snapshot[S]? raise GraphError {
  match self.latest(thread) {
    None => None
    Some(checkpoint) =>
      Some(checkpoint.into_snapshot(json => self.decode(json)))
  }
}

///|
fn[S] Checkpoint::into_snapshot(
  self : Checkpoint,
  decode : (Json) -> S raise GraphError,
) -> Snapshot[S] raise GraphError {
  let next : Array[String] = []
  for task in self.pending {
    next.push(task.node)
  }
  {
    thread: self.thread,
    id: self.id,
    parent: self.parent,
    step: self.step,
    state: decode(self.state),
    next,
    interrupt: self.interrupt,
    created_at: self.created_at,
  }
}

///|
/// Every checkpoint of the thread, oldest first: the path a run took, including
/// the ones an `update` forked away from.
pub async fn[S : @json.FromJson, U] Graph::history(
  self : Graph[S, U],
  thread : String,
) -> Array[Snapshot[S]] raise GraphError {
  let snapshots : Array[Snapshot[S]] = []
  match self.saver {
    Some(saver) =>
      for checkpoint in load_history(saver, thread) {
        snapshots.push(checkpoint.into_snapshot(json => self.decode(json)))
      }
    None => ()
  }
  snapshots
}

///|
/// Write `update` into the thread's latest state as if a node had written it,
/// and queue `as_node` — or, when absent, the tasks of the step that produced
/// the checkpoint — to run next. A `run` afterwards continues from there, which
/// is how a finished thread is taken back to an earlier decision.
pub async fn[S : @json.ToJson + @json.FromJson, U] Graph::update(
  self : Graph[S, U],
  thread : String,
  update : U,
  as_node? : String,
) -> Unit raise GraphError {
  let checkpoint = match self.latest(thread) {
    Some(checkpoint) => checkpoint
    None => raise GraphError::MissingThread(thread~)
  }
  let state = (self.merge)(self.decode(checkpoint.state), update)
  let pending : Array[Pending] = match as_node {
    Some(node) => {
      // `as_node` says which node wrote this, so what runs next is what would
      // have run after that node — not the node itself.
      if !self.nodes.contains(node) {
        raise GraphError::MissingNode(node~)
      }
      let next : Array[String] = []
      for to in self.successors(node) {
        push_unique(next, to)
      }
      for route in self.routes_of(node) {
        for to in route_from(route, state) {
          push_unique(next, to)
        }
      }
      next.map(node => ({ node, input: None, } : Pending))
    }
    None =>
      if checkpoint.pending.length() > 0 {
        checkpoint.pending
      } else {
        match self.saver {
          Some(saver) =>
            match load_history(saver, thread, limit=2) {
              [previous, _] if previous.pending.length() > 0 => previous.pending
              _ => [{ node: self.entry, input: None, }]
            }
          None => [{ node: self.entry, input: None, }]
        }
      }
  }
  let record = {
    thread,
    id: "cp-" + pad6(checkpoint.seq + 1),
    parent: Some(checkpoint.id),
    seq: checkpoint.seq + 1,
    step: 0,
    state: @json.to_json(state),
    pending,
    interrupt: None,
    created_at: @env.now().reinterpret_as_int64(),
    writes: None,
  }
  match self.saver {
    Some(saver) => save(saver, record)
    None => ()
  }
}

///|
/// Run a compiled graph as one node of another. The nested thread is named after
/// the parent's checkpoint, so re-entering the same parent superstep starts a
/// fresh child instead of reading the abandoned attempt's checkpoints.
async fn[T : @json.ToJson + @json.FromJson, V : @json.ToJson + @json.FromJson] Graph::run_nested(
  self : Graph[T, V],
  input : T,
  thread : String,
  inherited : &Saver?,
) -> T raise GraphError {
  let session = {
    ..self.fresh(thread, input, _ => ()),
    saver: match self.saver {
      Some(saver) => Some(saver)
      None => inherited
    },
  }
  drive(session)
}
