// The in-memory half of the checkpoint-conformance inventory. The integration
// module replays the same cases on four backends; these tests keep the contract
// honest under `moon test --target all`, where no database is reachable.

///|
fn conformance_checkpoint(
  thread : String,
  seq : Int32,
) -> @moonstate.Checkpoint {
  @moonstate.Checkpoint::{
    thread,
    id: "cp-00000" + seq.to_string(),
    parent: if seq == 0 {
      None
    } else {
      Some("cp-00000" + (seq - 1).to_string())
    },
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
async test "get answers the five shapes of a lookup" {
  let saver = @moonstate.MemorySaver::new()
  for seq in 0..<3 {
    saver.put(conformance_checkpoint("job", seq))
  }
  saver.put_writes("job", "cp-000001", "task-a", [Json(1)])
  assert_eq(saver.get("absent") is None, true)
  assert_eq(saver.get("job").unwrap().id, "cp-000002")
  assert_eq(saver.get("job", id="cp-000001").unwrap().step, 1)
  assert_eq(saver.get("job", id="cp-000009") is None, true)
  assert_eq(saver.get("job").unwrap().parent, Some("cp-000001"))
  let writes = saver.get("job", id="cp-000001").unwrap().writes.unwrap()
  assert_eq(writes.length(), 1)
  assert_eq(writes[0].task, "task-a")
  assert_eq(writes[0].values[0], Json(1))
}

///|
async test "put round-trips a state and replaces an existing id" {
  let saver = @moonstate.MemorySaver::new()
  saver.put(conformance_checkpoint("job", 0))
  assert_eq(
    saver.get("job", id="cp-000000").unwrap().state.stringify(),
    "{\"n\":0}",
  )
  let replaced = {
    ..conformance_checkpoint("job", 0),
    state: Json::object({ "n": Json(42) }),
  }
  saver.put(replaced)
  assert_eq(saver.list("job").length(), 1)
  assert_eq(
    saver.get("job", id="cp-000000").unwrap().state.stringify(),
    "{\"n\":42}",
  )
  saver.put(conformance_checkpoint("job", 1))
  saver.put(conformance_checkpoint("other", 0))
  assert_eq(saver.list("job").length(), 2)
  assert_eq(saver.list("other").length(), 1)
  assert_eq(saver.get("other").unwrap().thread, "other")
}

///|
async test "put_writes accumulates, replaces, and stays on its checkpoint" {
  let saver = @moonstate.MemorySaver::new()
  saver.put(conformance_checkpoint("job", 0))
  saver.put(conformance_checkpoint("job", 1))
  saver.put_writes("job", "cp-000000", "task-a", [Json(1)])
  saver.put_writes("job", "cp-000000", "task-b", [Json(2), Json(3)])
  saver.put_writes("job", "cp-000000", "task-a", [Json(9)])
  let writes = saver.get("job", id="cp-000000").unwrap().writes.unwrap()
  assert_eq(writes.length(), 2)
  assert_eq(writes[0].values[0], Json(9))
  assert_eq(writes[1].values.length(), 2)
  assert_eq(saver.get("job", id="cp-000001").unwrap().writes is None, true)
}

///|
async test "list honours before, limit, and both at once" {
  let saver = @moonstate.MemorySaver::new()
  for seq in 0..<5 {
    saver.put(conformance_checkpoint("job", seq))
  }
  saver.put_writes("job", "cp-000002", "task-a", [Json(1)])
  let ids = saver.list("job").map(checkpoint => checkpoint.id)
  assert_eq(ids, [
    "cp-000000", "cp-000001", "cp-000002", "cp-000003", "cp-000004",
  ])
  assert_eq(saver.list("job", limit=2).map(checkpoint => checkpoint.id), [
    "cp-000003", "cp-000004",
  ])
  assert_eq(
    saver.list("job", before="cp-000003").map(checkpoint => checkpoint.id),
    ["cp-000000", "cp-000001", "cp-000002"],
  )
  assert_eq(
    saver
    .list("job", limit=2, before="cp-000004")
    .map(checkpoint => checkpoint.id),
    ["cp-000002", "cp-000003"],
  )
  assert_eq(saver.list("job", before="cp-000000").length(), 0)
  let written = saver
    .list("job")
    .iter()
    .find_first(checkpoint => checkpoint.id == "cp-000002")
  assert_eq(written.unwrap().writes.unwrap().length(), 1)
}

///|
async test "delete removes checkpoints and writes and leaves other threads" {
  let saver = @moonstate.MemorySaver::new()
  saver.put(conformance_checkpoint("job", 0))
  saver.put_writes("job", "cp-000000", "task-a", [Json(1)])
  saver.put(conformance_checkpoint("other", 0))
  saver.delete("job")
  assert_eq(saver.get("job") is None, true)
  assert_eq(saver.list("job").length(), 0)
  saver.put(conformance_checkpoint("job", 0))
  assert_eq(saver.get("job", id="cp-000000").unwrap().writes is None, true)
  assert_eq(saver.list("other").length(), 1)
  saver.delete("never-there")
  assert_eq(saver.list("other").length(), 1)
}
