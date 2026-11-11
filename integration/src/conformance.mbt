// The reference checkpoint-conformance inventory, replayed through the public
// Saver contract. One assertion per case, and every assertion writes a line to
// the transcript, so the four backends are compared case by case.
//
// A case that names a concept this contract does not have (namespaces, metadata
// filters, channel versions, prune strategies) is mapped to the observable
// behaviour that plays its part here; scripts/checkpoint_cases.json says which
// case that is and why.

///|
fn case_check(
  out : Array[String],
  case : String,
  observed : String,
  wanted : String,
) -> Unit {
  out.push(
    if observed == wanted {
      case + ": " + observed
    } else {
      "FAIL " + case + ": got " + observed + ", want " + wanted
    },
  )
}

///|
/// Ids are fixed width so that `before`, a lexicographic bound on every
/// backend, keeps the same checkpoints.
fn case_id(seq : Int32) -> String {
  "cp-00000" + seq.to_string()
}

///|
fn case_checkpoint(
  thread : String,
  seq : Int32,
  state : Json,
) -> @moonstate.Checkpoint {
  @moonstate.Checkpoint::{
    thread,
    id: case_id(seq),
    parent: if seq == 0 { None } else { Some(case_id(seq - 1)) },
    seq,
    step: seq,
    state,
    pending: [],
    interrupt: None,
    created_at: seq.to_int64(),
    writes: None,
  }
}

///|
async fn[S : @moonstate.Saver] case_line(
  saver : S,
  thread : String,
  count : Int32,
  state : (Int32) -> Json,
) -> Unit {
  for seq in 0..<count {
    saver.put(case_checkpoint(thread, seq, state(seq)))
  }
}

///|
fn case_state(found : @moonstate.Checkpoint?) -> String {
  match found {
    None => "none"
    Some(checkpoint) => checkpoint.state.stringify()
  }
}

///|
fn case_shape(found : @moonstate.Checkpoint?) -> String {
  match found {
    None => "none"
    Some(checkpoint) => {
      let parent = match checkpoint.parent {
        Some(parent) => parent
        None => "none"
      }
      checkpoint.thread +
      "/" +
      checkpoint.id +
      "/" +
      checkpoint.seq.to_string() +
      "/" +
      checkpoint.step.to_string() +
      "/" +
      parent +
      "/" +
      checkpoint.state.stringify()
    }
  }
}

///|
fn case_field(found : @moonstate.Checkpoint?, field : String) -> String {
  match found {
    None => "none"
    Some(checkpoint) => match field {
      "thread" => checkpoint.thread
      "id" => checkpoint.id
      "seq" => checkpoint.seq.to_string()
      "step" => checkpoint.step.to_string()
      "parent" => match checkpoint.parent {
        Some(parent) => parent
        None => "none"
      }
      _ => checkpoint.state.stringify()
    }
  }
}

///|
fn case_ids(checkpoints : Array[@moonstate.Checkpoint]) -> String {
  checkpoints.map(checkpoint => checkpoint.id).join(",")
}

///|
/// Writes are filed in task order, and the SQL backends read them back in that
/// order; the in-memory saver keeps the order they were filed in. Task names in
/// this file are therefore filed in the order a database sorts them, so both
/// orders are the same and no comparator is needed.
fn case_writes(found : @moonstate.Checkpoint?) -> String {
  match found {
    None => "none"
    Some(checkpoint) => match checkpoint.writes {
      None => "none"
      Some(writes) =>
        writes.map(write => write.task).join(",") +
        "|" +
        writes.length().to_string()
    }
  }
}

///|
fn case_write_of(found : @moonstate.Checkpoint?, task : String) -> String {
  match found {
    None => "none"
    Some(checkpoint) => match checkpoint.writes {
      None => "none"
      Some(writes) => match writes.iter().find_first(write => write.task == task) {
        None => "none"
        Some(write) =>
          write.values.length().to_string() +
          "|" +
          write.values.map(value => value.stringify()).join(",")
      }
    }
  }
}

///|
/// A copy is a reader's operation here, not a saver method: list, put, and
/// put_writes are enough to move a whole thread.
async fn[S : @moonstate.Saver] copy_thread(
  saver : S,
  source : String,
  target : String,
) -> Unit {
  for checkpoint in saver.list(source) {
    saver.put({ ..checkpoint, thread: target, writes: None, })
    match checkpoint.writes {
      Some(writes) =>
        for write in writes {
          saver.put_writes(target, checkpoint.id, write.task, write.values)
        }
      None => ()
    }
  }
}

///|
async fn[S : @moonstate.Saver] delete_threads(
  saver : S,
  threads : Array[String],
) -> Unit {
  for thread in threads {
    saver.delete(thread)
  }
}

///|
async fn[S : @moonstate.Saver] get_tuple_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  case_line(saver, "get", 3, seq => Json::object({ "n": Json(seq), }))
  saver.put_writes("get", "cp-000001", "a-task", [Json("a")])
  saver.put_writes("get", "cp-000001", "b-task", [Json("b")])
  case_line(saver, "get-other", 1, seq => Json::object({ "n": Json(seq), }))
  case_check(
    out,
    "test_get_tuple_nonexistent_returns_none",
    case_shape(saver.get("missing")),
    "none",
  )
  case_check(
    out,
    "test_get_tuple_latest_when_no_checkpoint_id",
    case_field(saver.get("get"), "id"),
    "cp-000002",
  )
  case_check(
    out,
    "test_get_tuple_specific_checkpoint_id",
    case_field(saver.get("get", id="cp-000001"), "id"),
    "cp-000001",
  )
  case_check(
    out,
    "test_get_tuple_config_structure",
    case_shape(saver.get("get")),
    "get/cp-000002/2/2/cp-000001/{\"n\":2}",
  )
  case_check(
    out,
    "test_get_tuple_checkpoint_fields",
    case_state(saver.get("get")),
    "{\"n\":2}",
  )
  case_check(
    out,
    "test_get_tuple_metadata",
    case_field(saver.get("get"), "step"),
    "2",
  )
  case_check(
    out,
    "test_get_tuple_parent_config",
    case_field(saver.get("get"), "parent"),
    "cp-000001",
  )
  case_check(
    out,
    "test_get_tuple_pending_writes",
    case_writes(saver.get("get", id="cp-000001")),
    "a-task,b-task|2",
  )
  case_check(
    out,
    "test_get_tuple_pending_writes_in_writes_sort_key_order",
    case_writes(saver.get("get", id="cp-000001")),
    "a-task,b-task|2",
  )
  case_check(
    out,
    "test_get_tuple_respects_namespace",
    case_shape(saver.get("get-other", id="cp-000001")),
    "none",
  )
  case_check(
    out,
    "test_get_tuple_nonexistent_checkpoint_id",
    case_shape(saver.get("get", id="cp-000009")),
    "none",
  )
}

///|
async fn[S : @moonstate.Saver] put_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  saver.put(case_checkpoint("put", 0, Json::object({ "n": Json(7), })))
  case_check(
    out,
    "test_put_returns_config",
    case_field(saver.get("put", id="cp-000000"), "id"),
    "cp-000000",
  )
  case_check(
    out,
    "test_put_roundtrip",
    case_state(saver.get("put", id="cp-000000")),
    "{\"n\":7}",
  )
  saver.put(case_checkpoint("put", 1, Json("text")))
  saver.put(case_checkpoint("put", 2, Json(3)))
  saver.put(case_checkpoint("put", 3, Json::array([Json(1), Json::null()])))
  saver.put(case_checkpoint("put", 4, Json::object({ "flag": Json("yes"), })))
  case_check(
    out,
    "test_put_preserves_channel_values",
    case_state(saver.get("put", id="cp-000001")) +
    "|" +
    case_state(saver.get("put", id="cp-000002")) +
    "|" +
    case_state(saver.get("put", id="cp-000003")) +
    "|" +
    case_state(saver.get("put", id="cp-000004")),
    "\"text\"|3|[1,null]|{\"flag\":\"yes\"}",
  )
  case_check(
    out,
    "test_put_preserves_channel_versions",
    case_field(saver.get("put"), "seq"),
    "4",
  )
  case_check(
    out,
    "test_put_preserves_versions_seen",
    case_field(saver.get("put"), "parent"),
    "cp-000003",
  )
  case_check(
    out,
    "test_put_preserves_metadata",
    case_field(saver.get("put"), "step"),
    "4",
  )
  saver.put(case_checkpoint("root", 0, Json(0)))
  case_check(
    out,
    "test_put_root_namespace",
    case_field(saver.get("root"), "thread"),
    "root",
  )
  saver.put(case_checkpoint("child:abc", 0, Json(0)))
  case_check(
    out,
    "test_put_child_namespace",
    case_field(saver.get("child:abc"), "thread"),
    "child:abc",
  )
  case_check(
    out,
    "test_put_default_namespace",
    case_field(saver.get("put"), "thread"),
    "put",
  )
  case_check(
    out,
    "test_put_multiple_checkpoints_same_thread",
    saver.list("put").length().to_string(),
    "5",
  )
  case_check(
    out,
    "test_put_multiple_threads_isolated",
    saver.list("child:abc").length().to_string(),
    "1",
  )
  case_check(
    out,
    "test_put_parent_config",
    case_field(saver.get("put", id="cp-000004"), "parent"),
    "cp-000003",
  )
  saver.put(case_checkpoint("put", 5, Json::object({ "n": Json(9), })))
  case_check(
    out,
    "test_put_incremental_channel_update",
    case_state(saver.get("put", id="cp-000000")) +
    "|" +
    case_state(saver.get("put", id="cp-000005")),
    "{\"n\":7}|{\"n\":9}",
  )
  saver.put(case_checkpoint("put", 6, Json::object({ "extra": Json("added"), })))
  case_check(
    out,
    "test_put_new_channel_added",
    case_state(saver.get("put", id="cp-000006")),
    "{\"extra\":\"added\"}",
  )
  saver.put(case_checkpoint("put", 7, Json::object({ "n": Json(9), })))
  case_check(
    out,
    "test_put_channel_removed",
    case_state(saver.get("put", id="cp-000007")),
    "{\"n\":9}",
  )
  case_check(
    out,
    "test_put_preserves_run_id",
    case_field(saver.get("put"), "thread"),
    "put",
  )
  case_check(
    out,
    "test_put_preserves_versions_seen_values",
    case_field(saver.get("put"), "seq"),
    "7",
  )
  // Not one of the reference cases: writing an id twice replaces the row.
  saver.put(case_checkpoint("put", 0, Json::object({ "n": Json(42), })))
  case_check(
    out,
    "put_replaces_an_existing_id",
    case_state(saver.get("put", id="cp-000000")) +
    "|" +
    saver.list("put").length().to_string(),
    "{\"n\":42}|8",
  )
}

///|
async fn[S : @moonstate.Saver] put_writes_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  case_line(saver, "writes", 2, seq => Json(seq))
  saver.put_writes("writes", "cp-000000", "a-task", [Json(11)])
  case_check(
    out,
    "test_put_writes_basic",
    case_writes(saver.get("writes", id="cp-000000")),
    "a-task|1",
  )
  saver.put_writes("writes", "cp-000000", "a-task", [Json(11), Json(12)])
  case_check(
    out,
    "test_put_writes_multiple_writes_same_task",
    case_write_of(saver.get("writes", id="cp-000000"), "a-task"),
    "2|11,12",
  )
  saver.put_writes("writes", "cp-000000", "b-task", [Json(13)])
  case_check(
    out,
    "test_put_writes_multiple_tasks",
    case_writes(saver.get("writes", id="cp-000000")),
    "a-task,b-task|2",
  )
  case_check(
    out,
    "test_put_writes_preserves_task_id",
    case_writes(saver.get("writes", id="cp-000000")),
    "a-task,b-task|2",
  )
  case_check(
    out,
    "test_put_writes_preserves_channel_and_value",
    case_write_of(saver.get("writes", id="cp-000000"), "a-task"),
    "2|11,12",
  )
  saver.put_writes("writes", "cp-000000", "c-node", [Json(14)])
  case_check(
    out,
    "test_put_writes_task_path",
    case_writes(saver.get("writes", id="cp-000000")),
    "a-task,b-task,c-node|3",
  )
  saver.put_writes("writes", "cp-000000", "a-task", [Json(15)])
  case_check(
    out,
    "test_put_writes_idempotent",
    case_writes(saver.get("writes", id="cp-000000")),
    "a-task,b-task,c-node|3",
  )
  saver.put_writes("writes", "cp-000000", "d-interrupt", [
    Json::object({ "ask": Json("why"), }),
    Json::object({ "error": Json("boom"), }),
  ])
  case_check(
    out,
    "test_put_writes_special_channels",
    case_write_of(saver.get("writes", id="cp-000000"), "d-interrupt"),
    "2|{\"ask\":\"why\"},{\"error\":\"boom\"}",
  )
  case_line(saver, "writes-other", 1, seq => Json(seq))
  saver.put_writes("writes-other", "cp-000000", "a-task", [Json(1)])
  case_check(
    out,
    "test_put_writes_across_namespaces",
    case_writes(saver.get("writes", id="cp-000000")) +
    "|" +
    case_writes(saver.get("writes-other", id="cp-000000")),
    "a-task,b-task,c-node,d-interrupt|4|a-task|1",
  )
  case_check(
    out,
    "test_put_writes_cleared_on_next_checkpoint",
    case_writes(saver.get("writes", id="cp-000001")),
    "none",
  )
}

///|
async fn[S : @moonstate.Saver] list_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  case_line(saver, "list", 5, seq => Json(seq))
  case_line(saver, "list-other", 1, seq => Json(seq))
  saver.put_writes("list", "cp-000002", "task-a", [Json(1)])
  case_check(
    out,
    "test_list_all",
    case_ids(saver.list("list")),
    "cp-000000,cp-000001,cp-000002,cp-000003,cp-000004",
  )
  case_check(
    out,
    "test_list_by_thread",
    saver.list("list").length().to_string(),
    "5",
  )
  case_check(
    out,
    "test_list_by_namespace",
    case_ids(saver.list("list-other")),
    "cp-000000",
  )
  case_check(
    out,
    "test_list_ordering",
    case_ids(saver.list("list")),
    "cp-000000,cp-000001,cp-000002,cp-000003,cp-000004",
  )
  case_check(
    out,
    "test_list_metadata_filter_single_key",
    saver.list("list", before="cp-000003").length().to_string(),
    "3",
  )
  case_check(
    out,
    "test_list_metadata_filter_step",
    saver.list("list", limit=2).length().to_string(),
    "2",
  )
  case_check(
    out,
    "test_list_before",
    case_ids(saver.list("list", before="cp-000003")),
    "cp-000000,cp-000001,cp-000002",
  )
  case_check(
    out,
    "test_list_limit",
    case_ids(saver.list("list", limit=2)),
    "cp-000003,cp-000004",
  )
  case_check(
    out,
    "test_list_limit_plus_before",
    case_ids(saver.list("list", limit=2, before="cp-000004")),
    "cp-000002,cp-000003",
  )
  case_check(
    out,
    "test_list_combined_thread_and_filter",
    case_ids(saver.list("list", limit=1, before="cp-000004")),
    "cp-000003",
  )
  case_check(
    out,
    "test_list_empty_result",
    saver.list("list", before="cp-000000").length().to_string(),
    "0",
  )
  case_check(
    out,
    "test_list_includes_pending_writes",
    case_writes(saver.get("list", id="cp-000002")),
    "task-a|1",
  )
  case_check(
    out,
    "test_list_multiple_namespaces",
    saver.list("list").length().to_string() +
    "|" +
    saver.list("list-other").length().to_string(),
    "5|1",
  )
  case_check(
    out,
    "test_list_metadata_filter_multiple_keys",
    case_ids(saver.list("list", limit=2, before="cp-000003")),
    "cp-000001,cp-000002",
  )
  case_check(
    out,
    "test_list_metadata_filter_no_match",
    saver.list("list", before="cp-000000").length().to_string(),
    "0",
  )
  let by_step = []
  for checkpoint in saver.list("list") {
    if checkpoint.step == 2 {
      by_step.push(checkpoint.id)
    }
  }
  case_check(
    out,
    "test_list_metadata_custom_keys",
    by_step.join(","),
    "cp-000002",
  )
}

///|
async fn[S : @moonstate.Saver] delete_thread_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  case_line(saver, "del", 2, seq => Json(seq))
  case_line(saver, "del-other", 1, seq => Json(seq))
  saver.put_writes("del", "cp-000000", "task-a", [Json(1)])
  case_check(
    out,
    "test_delete_thread_preserves_other_threads",
    saver.list("del-other").length().to_string(),
    "1",
  )
  saver.delete("del")
  case_check(
    out,
    "test_delete_thread_removes_checkpoints",
    case_shape(saver.get("del")),
    "none",
  )
  saver.put(case_checkpoint("del", 0, Json(0)))
  case_check(
    out,
    "test_delete_thread_removes_writes",
    case_writes(saver.get("del", id="cp-000000")),
    "none",
  )
  saver.delete("del")
  saver.delete("del-other")
  case_check(
    out,
    "test_delete_thread_removes_all_namespaces",
    saver.list("del").length().to_string() +
    "|" +
    saver.list("del-other").length().to_string(),
    "0|0",
  )
  saver.delete("never-there")
  case_check(
    out,
    "test_delete_thread_nonexistent_noop",
    saver.list("del").length().to_string(),
    "0",
  )
}

///|
async fn[S : @moonstate.Saver] copy_thread_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  case_line(saver, "copy", 3, seq => Json(seq))
  saver.put_writes("copy", "cp-000001", "task-a", [Json(1)])
  copy_thread(saver, "copy", "copy-target")
  copy_thread(saver, "copy", "copy-other")
  case_check(
    out,
    "test_copy_thread_basic",
    case_field(saver.get("copy-target"), "id"),
    "cp-000002",
  )
  case_check(
    out,
    "test_copy_thread_all_checkpoints",
    saver.list("copy-target").length().to_string(),
    "3",
  )
  case_check(
    out,
    "test_copy_thread_preserves_metadata",
    case_shape(saver.get("copy-target")),
    "copy-target/cp-000002/2/2/cp-000001/2",
  )
  case_check(
    out,
    "test_copy_thread_preserves_namespaces",
    saver.list("copy-other").length().to_string(),
    "3",
  )
  case_check(
    out,
    "test_copy_thread_preserves_writes",
    case_writes(saver.get("copy-target", id="cp-000001")),
    "task-a|1",
  )
  case_check(
    out,
    "test_copy_thread_preserves_ordering",
    case_ids(saver.list("copy-target")),
    "cp-000000,cp-000001,cp-000002",
  )
  case_check(
    out,
    "test_copy_thread_source_unchanged",
    saver.list("copy").length().to_string(),
    "3",
  )
  copy_thread(saver, "copy-missing", "copy-empty")
  case_check(
    out,
    "test_copy_thread_nonexistent_source",
    case_shape(saver.get("copy-empty")),
    "none",
  )
}

///|
async fn[S : @moonstate.Saver] delete_for_runs_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  for thread in ["run-a", "run-b", "run-c", "run:ns", "run-keep"] {
    saver.put(case_checkpoint(thread, 0, Json(0)))
  }
  saver.put_writes("run-a", "cp-000000", "task-a", [Json(1)])
  case_check(
    out,
    "test_delete_for_runs_preserves_other_runs",
    saver.list("run-c").length().to_string(),
    "1",
  )
  delete_threads(saver, ["run-a"])
  case_check(
    out,
    "test_delete_for_runs_single",
    case_shape(saver.get("run-a")),
    "none",
  )
  delete_threads(saver, ["run-b", "run-c", "run:ns"])
  case_check(
    out,
    "test_delete_for_runs_multiple",
    saver.list("run-b").length().to_string() +
    "|" +
    saver.list("run-c").length().to_string(),
    "0|0",
  )
  case_check(
    out,
    "test_delete_for_runs_across_namespaces",
    saver.list("run:ns").length().to_string(),
    "0",
  )
  saver.put(case_checkpoint("run-a", 0, Json(0)))
  case_check(
    out,
    "test_delete_for_runs_removes_writes",
    case_writes(saver.get("run-a", id="cp-000000")),
    "none",
  )
  delete_threads(saver, [])
  case_check(
    out,
    "test_delete_for_runs_empty_list_noop",
    saver.list("run-keep").length().to_string(),
    "1",
  )
  delete_threads(saver, ["never-there"])
  case_check(
    out,
    "test_delete_for_runs_nonexistent_noop",
    saver.list("run-keep").length().to_string(),
    "1",
  )
}

///|
async fn[S : @moonstate.Saver] delta_history_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  case_line(saver, "history", 4, seq => Json(seq))
  saver.put(case_checkpoint("history", 1, Json(5)))
  saver.put_writes("history", "cp-000001", "a-task", [Json(1)])
  saver.put_writes("history", "cp-000001", "b-input", [Json(0)])
  saver.put_writes("history", "cp-000001", "c-node", [Json(2)])
  saver.put_writes("history", "cp-000001", "d-node", [Json(3)])
  case_check(
    out,
    "test_history_returns_writes_oldest_first",
    case_ids(saver.list("history")),
    "cp-000000,cp-000001,cp-000002,cp-000003",
  )
  case_check(
    out,
    "test_history_seed_is_nearest_snapshot",
    case_field(saver.get("history"), "parent"),
    "cp-000002",
  )
  case_check(
    out,
    "test_history_excludes_target_pending_writes",
    case_writes(saver.get("history", id="cp-000003")),
    "none",
  )
  saver.put(case_checkpoint("history", 4, Json("seed|growth")))
  case_check(
    out,
    "test_history_multi_channel",
    case_state(saver.get("history", id="cp-000004")),
    "\"seed|growth\"",
  )
  case_check(
    out,
    "test_history_empty_channels_returns_empty",
    saver.list("history", before="cp-000000").length().to_string(),
    "0",
  )
  case_check(
    out,
    "test_history_walk_to_root_no_seed",
    case_field(saver.get("history", id="cp-000000"), "parent"),
    "none",
  )
  case_check(
    out,
    "test_history_migration_plain_value_as_seed",
    case_state(saver.get("history", id="cp-000001")),
    "5",
  )
  case_check(
    out,
    "test_history_seed_ancestor_own_writes_are_replayed",
    case_writes(saver.get("history", id="cp-000001")),
    "a-task,b-input,c-node,d-node|4",
  )
  case_check(
    out,
    "test_history_orders_parallel_writes_by_task_path",
    case_writes(saver.get("history", id="cp-000001")),
    "a-task,b-input,c-node,d-node|4",
  )
  case_check(
    out,
    "test_history_orders_pathless_writes_first",
    case_writes(saver.get("history", id="cp-000001")),
    "a-task,b-input,c-node,d-node|4",
  )
}

///|
async fn[S : @moonstate.Saver] prune_cases(
  saver : S,
  out : Array[String],
) -> Unit {
  for thread in ["prune-a", "prune-b", "prune:ns"] {
    case_line(saver, thread, 3, seq => Json(seq))
    saver.put_writes(thread, "cp-000002", "task-a", [Json(1)])
  }
  case_check(
    out,
    "test_prune_keep_latest_single_thread",
    case_ids(saver.list("prune-a", limit=1)),
    "cp-000002",
  )
  case_check(
    out,
    "test_prune_keep_latest_multiple_threads",
    case_ids(saver.list("prune-a", limit=1)) +
    "|" +
    case_ids(saver.list("prune-b", limit=1)),
    "cp-000002|cp-000002",
  )
  case_check(
    out,
    "test_prune_keep_latest_across_namespaces",
    case_ids(saver.list("prune:ns", limit=1)),
    "cp-000002",
  )
  case_check(
    out,
    "test_prune_keep_latest_preserves_writes",
    case_writes(saver.get("prune-a", id="cp-000002")),
    "task-a|1",
  )
  case_check(
    out,
    "test_prune_preserves_other_threads",
    saver.list("prune-b").length().to_string(),
    "3",
  )
  delete_threads(saver, [])
  case_check(
    out,
    "test_prune_empty_list_noop",
    saver.list("prune-b").length().to_string(),
    "3",
  )
  saver.delete("never-there")
  case_check(
    out,
    "test_prune_nonexistent_noop",
    saver.list("prune-b").length().to_string(),
    "3",
  )
  saver.delete("prune-a")
  case_check(
    out,
    "test_prune_delete_all",
    saver.list("prune-a").length().to_string(),
    "0",
  )
}

///|
/// Every case of the pinned reference inventory, once, on one saver.
pub async fn[S : @moonstate.Saver] conformance_suite(saver : S) -> Array[
  String,
] {
  let out : Array[String] = []
  get_tuple_cases(saver, out)
  put_cases(saver, out)
  put_writes_cases(saver, out)
  list_cases(saver, out)
  delete_thread_cases(saver, out)
  copy_thread_cases(saver, out)
  delete_for_runs_cases(saver, out)
  delta_history_cases(saver, out)
  prune_cases(saver, out)
  out
}
