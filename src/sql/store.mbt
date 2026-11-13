///|
/// Long-term memory in a SQL table: spaced keys, each holding one JSON value.
///
/// The store is meant to outlive a thread, so it shares the connection discipline
/// with the saver: one connection, one mutex, one saver and one store per
/// connection.
pub struct SqlStore[T] {
  driver : T
  names : Names
  statements : Statements
  lock : @async.Mutex
  dialect : @moondb.Dialect
}

///|
/// A store over `driver`, using the tables in `names`. `setup` on a saver of the
/// same tables creates what this needs.
///
/// `dialect` overrides what the driver reports, the way `saver`'s does.
pub fn[T : @moondb.AsyncDriver] store(
  driver : T,
  names? : Names,
  dialect? : @moondb.Dialect,
) -> SqlStore[T] {
  let names = names.unwrap_or(preset_names())
  let dialect = dialect.unwrap_or(driver.dialect())
  {
    driver,
    names,
    statements: statements_of(dialect, names),
    lock: @async.Mutex::Mutex(),
    dialect,
  }
}

///|
/// Create the tables and indexes if they are not there.
pub async fn[T : @moondb.AsyncDriver] SqlStore::setup(
  self : SqlStore[T],
) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  for statement in self.statements.create {
    let _ = self.driver.execute(statement, [])
  }
}

///|
fn decode_item(row : @moondb.Row) -> @moonstate.Item raise {
  let stored = text_of(row, 0, "space")
  let value = json_of(row, 2, "body")
  { space: space_parts(stored), key: text_of(row, 1, "name"), value, }
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Store for SqlStore[T] with fn get(
  self,
  space,
  key,
) -> @moonstate.Item? raise {
  self.lock.acquire()
  defer self.lock.release()
  let rows = self.driver.query(self.statements.item_get, [
    @moondb.Text(space_text(space)),
    @moondb.Text(key),
  ])
  match rows {
    [] => None
    [row, ..] => Some(decode_item(row))
  }
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Store for SqlStore[T] with fn put(
  self,
  space,
  key,
  value,
) -> Unit raise {
  self.lock.acquire()
  defer self.lock.release()
  let _ = self.driver.execute(self.statements.item_put, [
    @moondb.Text(space_text(space)),
    @moondb.Text(key),
    @moondb.Text(@moonjson.dumps(value)),
    @moondb.Int64(@env.now().reinterpret_as_int64()),
  ])
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Store for SqlStore[T] with fn delete(
  self,
  space,
  key,
) -> Unit raise {
  self.lock.acquire()
  defer self.lock.release()
  let _ = self.driver.execute(self.statements.item_delete, [
    @moondb.Text(space_text(space)),
    @moondb.Text(key),
  ])
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Store for SqlStore[T] with fn search(
  self,
  space,
  query?,
  filter?,
  limit?,
) -> Array[@moonstate.Item] raise {
  self.lock.acquire()
  defer self.lock.release()
  let prefix = space_text(space)
  let narrowed = query is Some(_)
  let sql = search_text(self.dialect, self.names, prefix, narrowed)
  let params = match query {
    Some(text) => [@moondb.Text(prefix), @moondb.Text(text)]
    None => [@moondb.Text(prefix)]
  }
  let rows = self.driver.query(sql, params)
  let wanted = match limit {
    Some(limit) => limit
    None => 10
  }
  let found : Array[@moonstate.Item] = []
  for row in rows {
    let item = decode_item(row)
    match filter {
      Some(filter) => if !matches(item, filter) { continue }
      None => ()
    }
    found.push(item)
    if found.length() >= wanted {
      break
    }
  }
  found
}

///|
/// Whether an item's top-level object fields hold every value in `filter`. An item
/// that is not an object matches only an empty filter, as in the in-memory store.
fn matches(item : @moonstate.Item, filter : Map[String, Json]) -> Bool {
  guard item.value is Object(fields) else { return filter.is_empty() }
  for name, wanted in filter {
    match fields.get(name) {
      Some(actual) => if actual != wanted { return false }
      None => return false
    }
  }
  true
}

///|
pub extend SqlStore with @moonstate.Store::{get, put, delete, search}
