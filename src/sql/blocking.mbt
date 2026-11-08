///|
/// A blocking driver seen as an asynchronous one.
///
/// The seam this package writes against is `AsyncDriver`, because a checkpointer
/// awaits its database and a wire backend can only be awaited. A driver whose work
/// happens in a C call — SQLite is the one that ships — implements the synchronous
/// `Driver` instead, and reaches this package through here: the call blocks the
/// task it is made in, which is what a synchronous driver does anyway.
pub struct Blocking[T] {
  driver : T
}

///|
/// Wrap `driver` so it can be handed to `saver` or `store`.
///
/// ```moonbit nocheck
/// let connection = @moonsqlite.SqliteDriver::open("state.db")
///
/// let saver = @sql.saver(@sql.blocking(connection))
/// ```
pub fn[T] blocking(driver : T) -> Blocking[T] {
  { driver, }
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn execute(
  self,
  sql,
  params,
) -> @moondb.ExecResult raise @moondb.DbError {
  self.driver.execute(sql, params)
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn query(
  self,
  sql,
  params,
) -> Array[@moondb.Row] raise @moondb.DbError {
  self.driver.query(sql, params)
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn query_stream(
  self,
  sql,
  params,
) -> &@moondb.AsyncCursor raise @moondb.DbError {
  @moondb.AsyncArrayCursor::new(self.driver.query(sql, params))
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn begin(
  self,
) -> Unit raise @moondb.DbError {
  self.driver.begin()
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn commit(
  self,
) -> Unit raise @moondb.DbError {
  self.driver.commit()
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn rollback(
  self,
) -> Unit raise @moondb.DbError {
  self.driver.rollback()
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn close(
  self,
) -> Unit {
  self.driver.close()
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn ping(
  self,
) -> Bool {
  self.driver.ping()
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn dialect(
  self,
) -> @moondb.Dialect {
  self.driver.dialect()
}

///|
pub impl[T : @moondb.Driver] @moondb.AsyncDriver for Blocking[T] with fn capabilities(
  self,
) -> @moondb.Capabilities {
  self.driver.capabilities()
}

///|
pub extend Blocking with @moondb.AsyncDriver::{
  execute,
  query,
  query_stream,
  begin,
  commit,
  rollback,
  close,
  ping,
  prepare,
  dialect,
  capabilities,
}
