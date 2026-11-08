// The saver contract, checked on the in-memory implementation: the order a page
// comes back in, the two bounds, the writes that hang off a checkpoint, and the
// lineage a run leaves behind.

///|
#derive(@json.ToJson, @json.FromJson)
pub(all) struct Gauge {
  n : Int32
}

///|
pub extend Gauge with @json.ToJson::{to_json}

///|
pub extend Gauge with @json.FromJson::{from_json}

///|
#derive(@json.ToJson, @json.FromJson)
pub(all) struct Nudge {
  n : Int32?
}

///|
pub extend Nudge with @json.ToJson::{to_json}

///|
pub extend Nudge with @json.FromJson::{from_json}

///|
fn gauge_merge(state : Gauge, bump : Nudge) -> Gauge {
  { n: bump.n.unwrap_or(state.n), }
}

///|
/// The state before anything ran.
fn start() -> Gauge {
  { n: 0, }
}

///|
/// An update that changes nothing.
fn nothing() -> Nudge {
  { n: None, }
}

///|
/// An update that sets the count.
fn set(n : Int32) -> Nudge {
  { n: Some(n), }
}

///|
/// A checkpoint with everything a saver needs and nothing else.
fn checkpoint(
  thread : String,
  id : String,
  parent : String?,
  seq : Int32,
) -> @moonstate.Checkpoint {
  @moonstate.Checkpoint::{
    thread,
    id,
    parent,
    seq,
    step: seq,
    state: Json::object({ "n": Json(seq) }),
    pending: [],
    interrupt: None,
    created_at: seq.to_int64(),
    writes: None,
  }
}

///|
async test "a page is the newest checkpoints, oldest first" {
  let saver = @moonstate.MemorySaver::new()
  for seq in 0..<5 {
    let id = "cp-" + seq.to_string()
    saver.put(checkpoint("job", id, None, seq))
  }
  assert_eq(saver.list("job").map(one => one.id), [
    "cp-0", "cp-1", "cp-2", "cp-3", "cp-4",
  ])
  assert_eq(saver.list("job", limit=2).map(one => one.id), ["cp-3", "cp-4"])
  // `before` drops that checkpoint and everything after it, then the limit keeps
  // the newest of what is left.
  assert_eq(saver.list("job", limit=1).map(one => one.id), ["cp-4"])
  assert_eq(saver.list("job", before="cp-3").map(one => one.id), [
    "cp-0", "cp-1", "cp-2",
  ])
  assert_eq(saver.list("job", limit=2, before="cp-3").map(one => one.id), [
    "cp-1", "cp-2",
  ])
}

///|
async test "a write is filed under the checkpoint its task belongs to" {
  let saver = @moonstate.MemorySaver::new()
  saver.put(checkpoint("job", "cp-0", None, 0))
  saver.put_writes("job", "cp-0", "0:0:seed", [Json::object({ "n": Json(1) })])
  // The same task writing again replaces what it wrote before: a retried task
  // files one row, not two.
  saver.put_writes("job", "cp-0", "0:0:seed", [Json::object({ "n": Json(2) })])
  saver.put_writes("job", "cp-0", "0:1:other", [Json::object({ "n": Json(3) })])
  let stored = saver.get("job").unwrap()
  let writes = stored.writes.unwrap()
  assert_eq(writes.length(), 2)
  assert_eq(writes[0].task, "0:0:seed")
  assert_eq(writes[0].values.length(), 1)
  assert_eq(writes[0].values[0], Json::object({ "n": Json(2) }))
  // A checkpoint that nothing was filed under reports nothing, not an empty list.
  saver.put(checkpoint("job", "cp-1", Some("cp-0"), 1))
  assert_eq(saver.get("job").unwrap().writes is None, true)
}

///|
async test "delete takes the checkpoints and the writes with it" {
  let saver = @moonstate.MemorySaver::new()
  saver.put(checkpoint("job", "cp-0", None, 0))
  saver.put_writes("job", "cp-0", "0:0:seed", [])
  saver.put(checkpoint("other", "cp-0", None, 0))
  saver.delete("job")
  assert_eq(saver.get("job") is None, true)
  assert_eq(saver.list("job").length(), 0)
  // A neighbouring thread is untouched, which is what makes delete usable on a
  // shared database.
  assert_eq(saver.list("other").length(), 1)
}

///|
async test "a run leaves a chain of checkpoints, each pointing at its parent" {
  let saver = @moonstate.MemorySaver::new()
  let graph = @moonstate.Builder::new(merge=gauge_merge, initial=start())
    .entry("one")
    .node("one", (_state, _run) => [@moonstate.Write(set(1))])
    .node("two", (state, _run) => [@moonstate.Write(set(state.n + 1))])
    .edge("one", "two")
    .compile("line", saver~) catch {
      error =>
        abort("the graph does not compile: " + (error : Error).to_string())
    }
  let out = graph.run(nothing(), thread="job") catch {
    error => abort("the run failed: " + (error : Error).to_string())
  }
  assert_eq(out.n, 2)
  let history = graph.history("job")
  // One checkpoint per superstep, plus the one the finished state is written to.
  assert_eq(history.length(), 3)
  assert_eq(history[0].parent, None)
  for index = 1; index < history.length(); index = index + 1 {
    assert_eq(history[index].parent, Some(history[index - 1].id))
  }
  assert_eq(history.map(snapshot => snapshot.step), [0, 1, 2])
  assert_eq(history[0].next, ["one"])
  assert_eq(history[1].next, ["two"])
  assert_eq(history[2].next, [])
}
