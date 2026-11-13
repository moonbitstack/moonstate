// The two seams this package crosses when it talks to a backend: the JSON text a
// checkpoint is stored as, and the adapter that lets a synchronous driver serve
// the asynchronous saver. Both used to be written here; both now come from the
// family libraries, so the tests pin the behaviour at the boundary.

///|
/// A checkpoint's state leaves through moonjson's writer and comes back through
/// its strict reader unchanged. The `state` column holds this text, so the
/// document a resumed run reads is the one that was saved.
test "checkpoint state survives the JSON text round trip" {
  let state : Json = {
    "n": Json(3),
    "log": Json::array([Json("a"), Json("b")]),
    "ready": Json(true),
  }
  let text = @moonjson.dumps(state)
  assert_eq(@moonjson.loads(text, @moonjson.strict), state)
  // The writer is compact: a column holds one line, not a pretty-printed blob.
  assert_false(text.contains("\n"))
}

///|
/// A synchronous driver — SQLite's calls into C — reaches the saver through
/// moondb's blocking adapter, and the saver's statements run on it. This is the
/// seam `@blocking.Blocking::new` now provides in place of the bridge this
/// package used to carry.
async test "a blocking driver carries the saver's statements" {
  let db = @moondb.MockDriver::new()
  let adapter = @blocking.Blocking::new(db)
  assert_eq(adapter.dialect(), @moondb.Dialect::Sqlite)
  let storage = saver(adapter)
  storage.setup()
  // Every CREATE statement went through the synchronous driver and was recorded.
  assert_true(db.row_count() > 0)
}
