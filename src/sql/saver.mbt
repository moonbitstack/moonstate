///|
/// Checkpoints in a SQL table.
///
/// One connection, one mutex: the driver's connection carries one exchange at a
/// time, and two runs sharing a saver would otherwise interleave their statements
/// on it. Compile a graph with one saver per connection.
pub struct SqlSaver[T] {
  driver : T
  names : Names
  statements : Statements
  lock : @async.Mutex
  dialect : @moondb.Dialect
}

///|
/// A saver over `driver`, using the tables in `names`. Nothing is written until
/// `setup` has run: a saver does not create tables behind the caller's back,
/// because a service account is often not allowed to.
///
/// ```moonbit nocheck
/// let saver = @sql.saver(connection)
/// saver.setup()
/// let graph = builder.compile("job", saver=saver)
/// ```
///
/// `dialect` overrides what the driver reports. A driver that numbers its
/// parameters has to report its own dialect for this to be unnecessary; until it
/// does, naming it here is the difference between one statement working and the
/// first one being rejected by the server.
pub fn[T : @moondb.AsyncDriver] saver(
  driver : T,
  names? : Names,
  dialect? : @moondb.Dialect,
) -> SqlSaver[T] {
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
/// The dialect the driver reported, which is the one the statements were written
/// for.
pub fn[T] SqlSaver::dialect(self : SqlSaver[T]) -> @moondb.Dialect {
  self.dialect
}

///|
/// Create the tables and indexes if they are not there. Safe to run on every
/// start, and safe to run twice at the same time on the backends that allow it.
pub async fn[T : @moondb.AsyncDriver] SqlSaver::setup(
  self : SqlSaver[T],
) -> Unit {
  self.lock.acquire()
  defer self.lock.release()
  for statement in self.statements.create {
    let _ = self.driver.execute(statement, [])
  }
}

///|
/// Drop every checkpoint and every write of one thread. A row that is already gone
/// is not an error.
pub async fn[T : @moondb.AsyncDriver] SqlSaver::forget(
  self : SqlSaver[T],
  thread : String,
) -> Unit {
  self.drop(thread)
}

///|
async fn[T : @moondb.AsyncDriver] SqlSaver::drop(
  self : SqlSaver[T],
  thread : String,
) -> Unit {
  let _ = self.driver.execute(self.statements.drop_writes, [
    @moondb.Text(thread),
  ])
  let _ = self.driver.execute(self.statements.drop_checkpoints, [
    @moondb.Text(thread),
  ])
}

///|
fn text_of(row : @moondb.Row, column : Int32, name : String) -> String raise {
  row.text(column) catch {
    error => raise Failed::Unreadable(column=name, reason="\{error}")
  }
}

///|
fn optional_text(
  row : @moondb.Row,
  column : Int32,
  name : String,
) -> String? raise {
  if row.is_null(column) {
    None
  } else {
    Some(text_of(row, column, name))
  }
}

///|
fn json_of(row : @moondb.Row, column : Int32, name : String) -> Json raise {
  let text = text_of(row, column, name)
  @json.parse(text) catch {
    error => raise Failed::Unreadable(column=name, reason="\{error}")
  }
}

///|
fn decode_checkpoint(row : @moondb.Row) -> @moonstate.Checkpoint raise {
  let pending : Array[@moonstate.Pending] = @json.from_json(
    json_of(row, 6, "pending"),
  ) catch {
    error => raise Failed::Unreadable(column="pending", reason="\{error}")
  }
  let interrupt = match optional_text(row, 7, "interrupt") {
    Some(text) =>
      Some(
        @json.parse(text) catch {
          error =>
            raise Failed::Unreadable(column="interrupt", reason="\{error}")
        },
      )
    None => None
  }
  {
    thread: text_of(row, 0, "thread"),
    id: text_of(row, 1, "id"),
    parent: optional_text(row, 2, "parent"),
    seq: row.int64(3).to_int(),
    step: row.int64(4).to_int(),
    state: json_of(row, 5, "state"),
    pending,
    interrupt,
    created_at: row.int64(8),
    writes: None,
  }
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Saver for SqlSaver[T] with fn get(
  self,
  thread,
  id?,
) -> @moonstate.Checkpoint? raise {
  self.lock.acquire()
  defer self.lock.release()
  let rows = match id {
    Some(id) =>
      self.driver.query(self.statements.one, [
        @moondb.Text(thread),
        @moondb.Text(id),
      ])
    None => self.driver.query(self.statements.latest, [@moondb.Text(thread)])
  }
  match rows {
    [] => None
    [row, ..] => {
      let checkpoint = decode_checkpoint(row)
      let writes = self.stored_writes(checkpoint.thread, checkpoint.id)
      Some({ ..checkpoint, writes, })
    }
  }
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Saver for SqlSaver[T] with fn put(
  self,
  checkpoint,
) -> Unit raise {
  self.lock.acquire()
  defer self.lock.release()
  let _ = self.driver.execute(self.statements.put, [
    @moondb.Text(checkpoint.thread),
    @moondb.Text(checkpoint.id),
    match checkpoint.parent {
      Some(parent) => @moondb.Text(parent)
      None => @moondb.Null
    },
    @moondb.Int64(checkpoint.seq.to_int64()),
    @moondb.Int64(checkpoint.step.to_int64()),
    @moondb.Text(checkpoint.state.stringify()),
    @moondb.Text(
      Json::array(checkpoint.pending.map(pending => pending.to_json())).stringify(),
    ),
    match checkpoint.interrupt {
      Some(value) => @moondb.Text(value.stringify())
      None => @moondb.Null
    },
    @moondb.Int64(checkpoint.created_at),
  ])
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Saver for SqlSaver[T] with fn put_writes(
  self,
  thread,
  id,
  task,
  values,
) -> Unit raise {
  self.lock.acquire()
  defer self.lock.release()
  let _ = self.driver.execute(self.statements.put_write, [
    @moondb.Text(thread),
    @moondb.Text(id),
    @moondb.Text(task),
    @moondb.Text(Json::array(values).stringify()),
  ])
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Saver for SqlSaver[T] with fn list(
  self,
  thread,
  limit?,
  before?,
) -> Array[@moonstate.Checkpoint] raise {
  self.lock.acquire()
  defer self.lock.release()
  let sql = list_text(self.dialect, self.names, before is Some(_), limit)
  let params = match before {
    Some(id) => [@moondb.Text(thread), @moondb.Text(id)]
    None => [@moondb.Text(thread)]
  }
  let rows = self.driver.query(sql, params)
  // The statement keeps the newest rows, which is the tail of the thread; the
  // contract hands them back oldest first.
  let checkpoints = []
  for row in rows.rev() {
    let checkpoint = decode_checkpoint(row)
    checkpoints.push({
      ..checkpoint,
      writes: self.stored_writes(checkpoint.thread, checkpoint.id),
    })
  }
  checkpoints
}

///|
pub impl[T : @moondb.AsyncDriver] @moonstate.Saver for SqlSaver[T] with fn delete(
  self,
  thread,
) -> Unit raise {
  self.lock.acquire()
  defer self.lock.release()
  self.drop(thread)
}

///|
/// The writes filed for one checkpoint. Called with the lock already held.
async fn[T : @moondb.AsyncDriver] SqlSaver::stored_writes(
  self : SqlSaver[T],
  thread : String,
  id : String,
) -> Array[@moonstate.TaskWrite]? {
  let rows = self.driver.query(self.statements.writes, [
    @moondb.Text(thread),
    @moondb.Text(id),
  ])
  if rows.length() == 0 {
    return None
  }
  let writes = []
  for row in rows {
    let values : Array[Json] = @json.from_json(json_of(row, 1, "steps")) catch {
      error => raise Failed::Unreadable(column="steps", reason="\{error}")
    }
    writes.push(@moonstate.TaskWrite::{ task: text_of(row, 0, "task"), values, })
  }
  Some(writes)
}

///|
pub extend SqlSaver with @moonstate.Saver::{get, put, put_writes, list, delete}
