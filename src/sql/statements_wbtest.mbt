///|
/// The checkpoint statements of one dialect, as text.
fn put_sql(dialect : @moondb.Dialect) -> String {
  statements_of(dialect, names).put
}

///|
test "each dialect spells its own upsert and its own placeholders" {
  let postgres = put_sql(@moondb.Dialect::Postgres)
  assert_true(postgres.contains("VALUES ($1, $2"))
  assert_true(
    postgres.contains(
      "ON CONFLICT (thread, id) DO UPDATE SET parent = excluded.parent",
    ),
  )
  let sqlite = put_sql(@moondb.Dialect::Sqlite)
  assert_true(sqlite.contains("VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"))
  assert_true(sqlite.contains("ON CONFLICT (thread, id) DO UPDATE SET"))
  let mysql = put_sql(@moondb.Dialect::Mysql)
  assert_true(mysql.contains("VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"))
  assert_true(mysql.contains("ON DUPLICATE KEY UPDATE parent = VALUES(parent)"))
  // The key columns are the conflict target, never an update of themselves.
  assert_false(mysql.contains("thread = VALUES(thread)"))
}

///|
test "mysql declares its indexes inside the table" {
  let mysql = statements_of(@moondb.Dialect::Mysql, names)
  assert_true(
    mysql.create[0].contains("KEY moonstate_checkpoint_by_seq (thread, seq)"),
  )
  for statement in mysql.create {
    assert_false(statement.contains("CREATE INDEX"))
  }
  let postgres = statements_of(@moondb.Dialect::Postgres, names)
  assert_true(
    postgres.create.contains(
      "CREATE INDEX IF NOT EXISTS moonstate_checkpoint_by_seq ON moonstate_checkpoint (thread, seq)",
    ),
  )
}

///|
test "a namespace and everything below it share a prefix" {
  assert_eq(space_text([]), "")
  assert_eq(space_text(["mem"]), "mem\u{1f}")
  assert_eq(space_text(["mem", "facts"]), "mem\u{1f}" + "facts\u{1f}")
  // A segment that contains the separator is escaped, and reads back whole.
  let nested = ["a\u{1fb}", "c\\d"]
  assert_eq(space_parts(space_text(nested)), nested)
  assert_eq(space_parts(""), [])
}

///|
test "the search compares a stored prefix instead of a pattern" {
  let sql = search_text(@moondb.Dialect::Postgres, names, "mem\u{1f}", true)
  assert_true(sql.contains("SUBSTR(space, 1, 4) = $1"))
  assert_true(sql.contains("STRPOS(body, $2) > 0"))
  let sqlite = search_text(@moondb.Dialect::Sqlite, names, "mem\u{1f}", true)
  assert_true(sqlite.contains("INSTR(body, ?) > 0"))
  // No `LIKE` either way: a namespace segment may hold a wildcard.
  assert_false(sqlite.contains("LIKE"))
  let plain = search_text(@moondb.Dialect::Sqlite, names, "mem\u{1f}", false)
  assert_false(plain.contains("INSTR"))
  assert_true(plain.contains("SUBSTR(space, 1, 4) = ?"))
}

///|
async test "put binds every column in the order the table declares them" {
  let driver = Recorder::new(@moondb.Dialect::Postgres)
  let saver = saver(driver)
  let checkpoint = @moonstate.Checkpoint::{
    thread: "job",
    id: "cp-000001",
    parent: Some("cp-000000"),
    seq: 1,
    step: 0,
    state: Json::object({ "n": Json(2) }),
    pending: [
      @moonstate.Pending::{
        node: "seed",
        input: Some(Json::object({ "n": Json(1) })),
      },
      @moonstate.Pending::{ node: "double", input: None, },
    ],
    interrupt: None,
    created_at: 7L,
    writes: None,
  }
  saver.put(checkpoint)
  let (sql, params) = driver.last_executed()
  assert_true(sql.has_prefix("INSERT INTO moonstate_checkpoint"))
  assert_eq(params.length(), 9)
  assert_eq(params[0], @moondb.Value::Text("job"))
  assert_eq(params[1], @moondb.Value::Text("cp-000001"))
  assert_eq(params[2], @moondb.Value::Text("cp-000000"))
  assert_eq(params[3], @moondb.Value::Int64(1L))
  assert_eq(params[4], @moondb.Value::Int64(0L))
  assert_eq(params[5], @moondb.Value::Text("{\"n\":2}"))
  assert_true(
    match params[6] {
      @moondb.Value::Text(text) => text.contains("\"node\":\"double\"")
      _ => false
    },
  )
  assert_eq(params[7], @moondb.Value::Null)
  assert_eq(params[8], @moondb.Value::Int64(7L))
}

///|
async test "get reads the latest checkpoint and the one it was asked for" {
  let driver = Recorder::new(@moondb.Dialect::Sqlite)
  let saver = saver(driver)
  driver.answer([
    checkpoint_row(
      "job",
      "cp-000002",
      Some("cp-000001"),
      2,
      1,
      "{}",
      "[]",
      None,
      9L,
    ),
  ])
  driver.answer([])
  let latest = saver.get("job").unwrap()
  let (sql, params) = driver.query_at(0)
  assert_true(sql.contains("ORDER BY seq DESC LIMIT 1"))
  assert_eq(params, [@moondb.Value::Text("job")])
  assert_eq(latest.id, "cp-000002")
  assert_eq(latest.seq, 2)
  assert_eq(latest.writes is None, true)
  driver.answer([
    checkpoint_row(
      "job",
      "cp-000004",
      None,
      4,
      2,
      "{}",
      "[]",
      Some("{\"ask\":\"ok\"}"),
      11L,
    ),
  ])
  driver.answer([])
  let one = saver.get("job", id="cp-000004").unwrap()
  let (sql, params) = driver.query_at(2)
  assert_true(sql.contains("AND id = ?"))
  assert_eq(params, [
    @moondb.Value::Text("job"),
    @moondb.Value::Text("cp-000004"),
  ])
  assert_eq(one.interrupt, Some(Json::object({ "ask": Json("ok") })))
  assert_eq(one.parent, None)
}

///|
async test "list keeps the newest checkpoints and hands them back oldest first" {
  let driver = Recorder::new(@moondb.Dialect::Postgres)
  let saver = saver(driver)
  driver.answer([
    checkpoint_row("job", "cp-000003", None, 3, 3, "{}", "[]", None, 0L),
    checkpoint_row("job", "cp-000002", None, 2, 2, "{}", "[]", None, 0L),
  ])
  driver.answer([])
  driver.answer([])
  let page = saver.list("job", limit=2)
  let (sql, params) = driver.query_at(0)
  assert_true(sql.contains("ORDER BY seq DESC LIMIT 2"))
  assert_eq(params, [@moondb.Value::Text("job")])
  assert_eq(page.map(checkpoint => checkpoint.id), ["cp-000002", "cp-000003"])
  // A bound adds the one predicate and keeps its own placeholder.
  driver.answer([])
  let _ = saver.list("job", limit=1, before="cp-000002")
  let (sql, params) = driver.query_at(3)
  assert_true(sql.contains("AND id < $2") && !sql.contains("LAST"))
  assert_true(sql.contains("ORDER BY seq DESC LIMIT 1"))
  assert_eq(params.length(), 2)
  assert_eq(params[1], @moondb.Value::Text("cp-000002"))
}

///|
async test "a task's writes come back attached to its checkpoint" {
  let driver = Recorder::new(@moondb.Dialect::Mysql)
  let saver = saver(driver)
  driver.answer([
    checkpoint_row("job", "cp-000000", None, 0, 0, "{}", "[]", None, 0L),
  ])
  driver.answer([
    @moondb.Row::{
      columns: ["task", "steps"],
      values: [
        @moondb.Value::Text("0:1:double"),
        @moondb.Value::Text("[{\"kind\":\"write\",\"value\":{\"n\":4}}]"),
      ],
    },
  ])
  let checkpoint = saver.get("job").unwrap()
  let writes = checkpoint.writes.unwrap()
  assert_eq(writes.length(), 1)
  assert_eq(writes[0].task, "0:1:double")
  assert_eq(writes[0].values.length(), 1)
}

///|
async test "put_writes replaces the row of the same task" {
  let driver = Recorder::new(@moondb.Dialect::Sqlite)
  let saver = saver(driver)
  saver.put_writes("job", "cp-000000", "0:0:seed", [
    Json::object({ "n": Json(1) }),
  ])
  let (sql, params) = driver.last_executed()
  assert_true(sql.has_prefix("INSERT INTO moonstate_write"))
  assert_true(
    sql.contains(
      "ON CONFLICT (thread, checkpoint, task) DO UPDATE SET steps = excluded.steps",
    ),
  )
  assert_eq(params.length(), 4)
  assert_eq(params[3], @moondb.Value::Text("[{\"n\":1}]"))
}

///|
async test "delete leaves both tables empty for the thread" {
  let driver = Recorder::new(@moondb.Dialect::Postgres)
  let saver = saver(driver)
  saver.delete("job")
  assert_eq(driver.executed.length(), 2)
  assert_true(driver.executed[0].0.has_prefix("DELETE FROM moonstate_write"))
  assert_true(
    driver.executed[1].0.has_prefix("DELETE FROM moonstate_checkpoint"),
  )
  assert_eq(driver.executed[1].1, [@moondb.Value::Text("job")])
}

///|
async test "a row that cannot be decoded names the column it came from" {
  let driver = Recorder::new(@moondb.Dialect::Sqlite)
  let saver = saver(driver)
  driver.answer([
    checkpoint_row("job", "cp-000000", None, 0, 0, "{oops", "[]", None, 0L),
  ])
  driver.answer([])
  let outcome = try {
    let _ = saver.get("job")
    "read"
  } catch {
    error => error.to_string()
  }
  assert_true(outcome.contains("state"))
}
