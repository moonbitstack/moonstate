///|
fn item_row(space : String, name : String, body : String) -> @moondb.Row {
  @moondb.Row::{
    columns: ["space", "name", "body"],
    values: [
      @moondb.Value::Text(space),
      @moondb.Value::Text(name),
      @moondb.Value::Text(body),
    ],
  }
}

///|
async test "an item is stored under its namespace and read back whole" {
  let driver = Recorder::new(@moondb.Dialect::Postgres)
  let store = store(driver)
  let _ = store.put(
    ["mem", "facts"],
    "capital",
    Json::object({ "city": Json("Oslo") }),
  )
  let (sql, params) = driver.last_executed()
  assert_true(sql.has_prefix("INSERT INTO moonstate_item"))
  assert_eq(params[0], @moondb.Value::Text("mem\u{1f}facts\u{1f}"))
  assert_eq(params[1], @moondb.Value::Text("capital"))
  assert_eq(params[2], @moondb.Value::Text("{\"city\":\"Oslo\"}"))
  driver.answer([
    item_row("mem\u{1f}facts\u{1f}", "capital", "{\"city\":\"Oslo\"}"),
  ])
  let item = store.get(["mem", "facts"], "capital").unwrap()
  let (sql, params) = driver.query_at(0)
  assert_true(sql.contains("WHERE space = $1 AND name = $2"))
  assert_eq(params[0], @moondb.Value::Text("mem\u{1f}facts\u{1f}"))
  assert_eq(item.space, ["mem", "facts"])
  assert_eq(item.key, "capital")
  assert_eq(item.value, Json::object({ "city": Json("Oslo") }))
}

///|
async test "a search covers the namespace below it and only the matching rows" {
  let driver = Recorder::new(@moondb.Dialect::Sqlite)
  let store = store(driver)
  driver.answer([
    item_row("mem\u{1f}", "a", "{\"tag\":\"keep\",\"text\":\"one\"}"),
    item_row("mem\u{1f}facts\u{1f}", "b", "{\"tag\":\"drop\",\"text\":\"two\"}"),
    item_row(
      "mem\u{1f}facts\u{1f}", "c", "{\"tag\":\"keep\",\"text\":\"three\"}",
    ),
  ])
  let found = store.search(
    ["mem"],
    query="t",
    filter={ "tag": Json("keep") },
    limit=5,
  )
  let (sql, params) = driver.query_at(0)
  // The namespace length is part of the statement, so the bound parameter stays
  // the first one in every shape.
  assert_true(sql.contains("SUBSTR(space, 1, 4) = ?"))
  assert_eq(params, [@moondb.Value::Text("mem\u{1f}"), @moondb.Value::Text("t")])
  assert_eq(found.map(item => item.key), ["a", "c"])
  driver.answer([
    item_row("mem\u{1f}", "a", "{}"),
    item_row("mem\u{1f}", "b", "{}"),
  ])
  let limited = store.search(["mem"], limit=1)
  assert_eq(limited.length(), 1)
}

///|
async test "a namespace is one value, so a key holding a wildcard still matches" {
  let driver = Recorder::new(@moondb.Dialect::Mysql)
  let store = store(driver)
  driver.answer([item_row("50%\u{1f}_x\u{1f}", "k", "{}")])
  let found = store.search(["50%", "_x"])
  assert_eq(found.length(), 1)
  assert_eq(found[0].space, ["50%", "_x"])
  let (sql, _) = driver.query_at(0)
  assert_false(sql.contains("LIKE"))
  assert_true(sql.contains("SUBSTR(space, 1, 7) = ?"))
}

///|
async test "delete asks for one exact namespace and key" {
  let driver = Recorder::new(@moondb.Dialect::Sqlite)
  let store = store(driver)
  store.delete(["mem"], "gone")
  let (sql, params) = driver.last_executed()
  assert_true(sql.has_prefix("DELETE FROM moonstate_item"))
  assert_eq(params, [
    @moondb.Value::Text("mem\u{1f}"),
    @moondb.Value::Text("gone"),
  ])
}

///|
async test "a store and a saver can name their own tables" {
  let mine : Names = {
    checkpoint: "job_cp",
    write: "job_write",
    item: "job_item",
  }
  let driver = Recorder::new(@moondb.Dialect::Postgres)
  let saver = saver(driver, names=mine)
  saver.setup()
  assert_true(
    driver.executed[0].0.contains("CREATE TABLE IF NOT EXISTS job_cp"),
  )
  assert_true(
    driver.executed[2].0.contains("CREATE TABLE IF NOT EXISTS job_item"),
  )
}
