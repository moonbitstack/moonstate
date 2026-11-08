// A driver that answers from a script and remembers what it was asked, so that
// the statements themselves — placeholder spelling, upsert form, bound values and
// the order of the rows handed back — are what the tests below check. The real
// backends are exercised in the integration workspace.

///|
struct Recorder {
  dialect_value : @moondb.Dialect
  executed : Array[(String, Array[@moondb.Value])]
  queries : Array[(String, Array[@moondb.Value])]
  answers : Array[Array[@moondb.Row]]
}

///|
fn Recorder::new(dialect : @moondb.Dialect) -> Recorder {
  { dialect_value: dialect, executed: [], queries: [], answers: [], }
}

///|
fn Recorder::answer(self : Recorder, rows : Array[@moondb.Row]) -> Unit {
  self.answers.push(rows)
}

///|
fn Recorder::last_executed(self : Recorder) -> (String, Array[@moondb.Value]) {
  self.executed[self.executed.length() - 1]
}

///|
fn Recorder::query_at(
  self : Recorder,
  index : Int32,
) -> (String, Array[@moondb.Value]) {
  self.queries[index]
}

///|
/// The `SELECT` list of the checkpoint table, so a canned row lines up with the
/// columns the decoder reads.
fn checkpoint_row(
  thread : String,
  id : String,
  parent : String?,
  seq : Int32,
  step : Int32,
  state : String,
  pending : String,
  interrupt : String?,
  created_at : Int64,
) -> @moondb.Row {
  @moondb.Row::{
    columns: [
      "thread", "id", "parent", "seq", "step", "state", "pending", "interrupt", "created_at",
    ],
    values: [
      @moondb.Value::Text(thread),
      @moondb.Value::Text(id),
      match parent {
        Some(parent) => @moondb.Value::Text(parent)
        None => @moondb.Value::Null
      },
      @moondb.Value::Int64(seq.to_int64()),
      @moondb.Value::Int64(step.to_int64()),
      @moondb.Value::Text(state),
      @moondb.Value::Text(pending),
      match interrupt {
        Some(value) => @moondb.Value::Text(value)
        None => @moondb.Value::Null
      },
      @moondb.Value::Int64(created_at),
    ],
  }
}

///|
impl @moondb.AsyncDriver for Recorder with fn execute(self, sql, params) -> @moondb.ExecResult raise @moondb.DbError {
  self.executed.push((sql, params))
  { rows_affected: 1, last_insert_id: 0, }
}

///|
impl @moondb.AsyncDriver for Recorder with fn query(self, sql, params) -> Array[
  @moondb.Row,
] raise @moondb.DbError {
  self.queries.push((sql, params))
  if self.answers.length() == 0 {
    []
  } else {
    self.answers.remove(0)
  }
}

///|
impl @moondb.AsyncDriver for Recorder with fn begin(_self) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.AsyncDriver for Recorder with fn commit(_self) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.AsyncDriver for Recorder with fn rollback(_self) -> Unit raise @moondb.DbError {

}

///|
impl @moondb.AsyncDriver for Recorder with fn close(_self) -> Unit {

}

///|
impl @moondb.AsyncDriver for Recorder with fn dialect(self) -> @moondb.Dialect {
  self.dialect_value
}

///|
impl @moondb.AsyncDriver for Recorder with fn capabilities(self) -> @moondb.Capabilities {
  @moondb.Capabilities::for_dialect(self.dialect_value)
}

///|
pub extend Recorder with @moondb.AsyncDriver::{
  execute,
  query,
  begin,
  commit,
  rollback,
  close,
  dialect,
  capabilities,
}
