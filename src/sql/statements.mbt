///|
/// Join `parts` with `separator`, without a trailing separator.
fn join_text(parts : Array[String], separator : String) -> String {
  let out = StringBuilder()
  for index, part in parts {
    if index > 0 {
      out.write_string(separator)
    }
    out.write_string(part)
  }
  out.to_string()
}

///|
/// The bound-parameter spelling for `count` values, in order: `$1, $2, …` on
/// PostgreSQL and `?, ?, …` on the two positional dialects.
fn placeholder_list(dialect : @moondb.Dialect, count : Int32) -> String {
  let parts : Array[String] = []
  for index = 0; index < count; index = index + 1 {
    parts.push(dialect.placeholder(index + 1))
  }
  join_text(parts, ", ")
}

///|
/// An insert that replaces the row when its key is already there.
///
/// SQLite and PostgreSQL spell the incoming row as `excluded` and name the
/// columns that clash; MySQL has one form for every table and reads the incoming
/// row through `VALUES(column)`. The MySQL form of the function is deprecated in
/// favour of a row alias in 8.0.20, but the alias does not exist in MariaDB, and
/// a saver that stops working on a MariaDB server to avoid a warning is the worse
/// trade.
fn upsert_text(
  dialect : @moondb.Dialect,
  table : String,
  columns : Array[String],
  keys : Array[String],
) -> String {
  let head = "INSERT INTO " +
    table +
    " (" +
    join_text(columns, ", ") +
    ") VALUES (" +
    placeholder_list(dialect, columns.length()) +
    ")"
  let updates : Array[String] = []
  for column in columns {
    if !keys.contains(column) {
      updates.push(column)
    }
  }
  match dialect {
    Mysql =>
      head +
      " ON DUPLICATE KEY UPDATE " +
      join_text(
        updates.map(column => column + " = VALUES(" + column + ")"),
        ", ",
      )
    _ =>
      head +
      " ON CONFLICT (" +
      join_text(keys, ", ") +
      ") DO UPDATE SET " +
      join_text(updates.map(column => column + " = excluded." + column), ", ")
  }
}

///|
/// `VARCHAR` lengths that keep every primary key inside MySQL's 3072-byte index
/// limit once the column is utf8mb4 — the one backend of the three that caps a key
/// at all.
let thread_type : String = "VARCHAR(255)"

///|
let id_type : String = "VARCHAR(64)"

///|
let task_type : String = "VARCHAR(255)"

///|
let space_type : String = "VARCHAR(512)"

///|
let name_type : String = "VARCHAR(192)"

///|
/// The columns of a checkpoint row, in the order `put` binds them.
let checkpoint_columns : Array[String] = [
  "thread", "id", "parent", "seq", "step", "state", "pending", "interrupt", "created_at",
]

///|
/// The columns of a write row.
let write_columns : Array[String] = ["thread", "checkpoint", "task", "steps"]

///|
/// The columns of a store row. `name` and `body` rather than `key` and `value`:
/// `KEY` and `VALUES` are reserved words in MySQL and would need quoting in every
/// statement.
let item_columns : Array[String] = ["space", "name", "body", "updated"]

///|
/// Every statement this package runs, built once for the dialect of the driver it
/// was given.
struct Statements {
  create : Array[String]
  put : String
  latest : String
  one : String
  writes : String
  put_write : String
  drop_checkpoints : String
  drop_writes : String
  item_get : String
  item_put : String
  item_delete : String
}

///|
/// The `SELECT` list of a checkpoint, in the order `decode_checkpoint` reads it.
let checkpoint_select : String = join_text(checkpoint_columns, ", ")

///|
/// Build the ddl for one table, plus the index the saver reads a thread's latest
/// checkpoint through. MySQL has no `CREATE INDEX IF NOT EXISTS`, so there the
/// index is declared inside the table.
fn create_checkpoint(dialect : @moondb.Dialect, table : String) -> String {
  let key_clause = match dialect {
    Mysql => ",\n  KEY " + table + "_by_seq (thread, seq)"
    _ => ""
  }
  "CREATE TABLE IF NOT EXISTS " +
  table +
  " (\n" +
  "  thread " +
  thread_type +
  " NOT NULL,\n" +
  "  id " +
  id_type +
  " NOT NULL,\n" +
  "  parent " +
  id_type +
  ",\n" +
  "  seq BIGINT NOT NULL,\n" +
  "  step BIGINT NOT NULL,\n" +
  "  state TEXT NOT NULL,\n" +
  "  pending TEXT NOT NULL,\n" +
  "  interrupt TEXT,\n" +
  "  created_at BIGINT NOT NULL,\n" +
  "  PRIMARY KEY (thread, id)" +
  key_clause +
  "\n)"
}

///|
fn create_index(dialect : @moondb.Dialect, table : String) -> String? {
  match dialect {
    Mysql => None
    _ =>
      Some(
        "CREATE INDEX IF NOT EXISTS " +
        table +
        "_by_seq ON " +
        table +
        " (thread, seq)",
      )
  }
}

///|
fn create_write(table : String) -> String {
  "CREATE TABLE IF NOT EXISTS " +
  table +
  " (\n" +
  "  thread " +
  thread_type +
  " NOT NULL,\n" +
  "  checkpoint " +
  id_type +
  " NOT NULL,\n" +
  "  task " +
  task_type +
  " NOT NULL,\n" +
  "  steps TEXT NOT NULL,\n" +
  "  PRIMARY KEY (thread, checkpoint, task)\n)"
}

///|
fn create_item(dialect : @moondb.Dialect, table : String) -> String {
  let key_clause = match dialect {
    Mysql => ",\n  KEY " + table + "_by_time (updated)"
    _ => ""
  }
  "CREATE TABLE IF NOT EXISTS " +
  table +
  " (\n" +
  "  space " +
  space_type +
  " NOT NULL,\n" +
  "  name " +
  name_type +
  " NOT NULL,\n" +
  "  body TEXT NOT NULL,\n" +
  "  updated BIGINT NOT NULL,\n" +
  "  PRIMARY KEY (space, name)" +
  key_clause +
  "\n)"
}

///|
/// The ddl of a fresh database, in the order it has to run.
fn create_statements(dialect : @moondb.Dialect, names : Names) -> Array[String] {
  let statements = [
    create_checkpoint(dialect, names.checkpoint),
    create_write(names.write),
    create_item(dialect, names.item),
  ]
  // The write table is read by its primary key, so it needs no index of its own.
  for index in [create_index(dialect, names.checkpoint)] {
    match index {
      Some(statement) => statements.push(statement)
      None => ()
    }
  }
  statements
}

///|
fn statements_of(dialect : @moondb.Dialect, names : Names) -> Statements {
  let checkpoint = names.checkpoint
  let write = names.write
  let item = names.item
  {
    create: create_statements(dialect, names),
    put: upsert_text(dialect, checkpoint, checkpoint_columns, ["thread", "id"]),
    latest: "SELECT " +
    checkpoint_select +
    " FROM " +
    checkpoint +
    " WHERE thread = " +
    dialect.placeholder(1) +
    " ORDER BY seq DESC LIMIT 1",
    one: "SELECT " +
    checkpoint_select +
    " FROM " +
    checkpoint +
    " WHERE thread = " +
    dialect.placeholder(1) +
    " AND id = " +
    dialect.placeholder(2),
    writes: "SELECT task, steps FROM " +
    write +
    " WHERE thread = " +
    dialect.placeholder(1) +
    " AND checkpoint = " +
    dialect.placeholder(2) +
    " ORDER BY task",
    put_write: upsert_text(dialect, write, write_columns, [
      "thread", "checkpoint", "task",
    ]),
    drop_checkpoints: "DELETE FROM " +
    checkpoint +
    " WHERE thread = " +
    dialect.placeholder(1),
    drop_writes: "DELETE FROM " +
    write +
    " WHERE thread = " +
    dialect.placeholder(1),
    item_get: "SELECT space, name, body FROM " +
    item +
    " WHERE space = " +
    dialect.placeholder(1) +
    " AND name = " +
    dialect.placeholder(2),
    item_put: upsert_text(dialect, item, item_columns, ["space", "name"]),
    item_delete: "DELETE FROM " +
    item +
    " WHERE space = " +
    dialect.placeholder(1) +
    " AND name = " +
    dialect.placeholder(2),
  }
}

///|
/// The page of a thread's checkpoints: the tails of the statement are assembled
/// per call because `list` takes four shapes out of two optional bounds, and four
/// strings built up front would be four things to keep in step.
fn list_text(
  dialect : @moondb.Dialect,
  names : Names,
  before : Bool,
  limit : Int32?,
) -> String {
  let head = "SELECT " +
    checkpoint_select +
    " FROM " +
    names.checkpoint +
    " WHERE thread = " +
    dialect.placeholder(1)
  let middle = if before { " AND id < " + dialect.placeholder(2) } else { "" }
  // Newest first here and reversed by the caller: the bound has to keep the most
  // recent checkpoints, and a `LIMIT` keeps the head of the order it is given.
  let tail = match limit {
    Some(limit) => " ORDER BY seq DESC LIMIT " + limit.to_string()
    None => " ORDER BY seq DESC"
  }
  head + middle + tail
}

///|
/// The stored form of a namespace: the segments joined by a separator that no
/// path segment can contain after `space_text` has encoded it, and closed by one so
/// that a namespace and everything below it share a prefix.
fn space_text(space : Array[String]) -> String {
  let out = StringBuilder()
  for part in space {
    out.write_string(encode_segment(part))
    out.write_char('\u{1f}')
  }
  out.to_string()
}

///|
/// A segment with the separator written as an escape, so that a name containing
/// it still round-trips.
fn encode_segment(part : String) -> String {
  let out = StringBuilder()
  for char in part {
    if char == '\u{1f}' || char == '\\' {
      out.write_char('\\')
    }
    out.write_char(char)
  }
  out.to_string()
}

///|
/// The inverse of `space_text`: the segments of a stored namespace.
fn space_parts(stored : String) -> Array[String] {
  let parts : Array[String] = []
  let current = StringBuilder()
  for char in stored {
    if char == '\u{1f}' {
      parts.push(current.to_string())
      current.reset()
    } else {
      current.write_char(char)
    }
  }
  parts.map(part => decode_segment(part))
}

///|
fn decode_segment(part : String) -> String {
  let out = StringBuilder()
  let mut escaped = false
  for char in part {
    if escaped {
      out.write_char(char)
      escaped = false
    } else if char == '\\' {
      escaped = true
    } else {
      out.write_char(char)
    }
  }
  out.to_string()
}

///|
/// The search over the store, narrowed by the space and the text.
///
/// The namespace is matched by comparing the stored prefix — no `LIKE`, because a
/// namespace segment may contain `%` or `_` and every backend would then need its
/// own escape clause. `SUBSTR` counts characters on all three backends, so the
/// comparison means the same thing on each.
///
/// The object-field filter stays out: SQL has three different spellings for
/// reaching into a JSON document, and filtering a handful of rows here is cheaper
/// than three statements to keep right.
fn search_text(
  dialect : @moondb.Dialect,
  names : Names,
  prefix : String,
  narrowed : Bool,
) -> String {
  let position = match dialect {
    Postgres => "STRPOS(body, "
    _ => "INSTR(body, "
  }
  let text = if narrowed {
    " AND " + position + dialect.placeholder(2) + ") > 0"
  } else {
    ""
  }
  "SELECT space, name, body FROM " +
  names.item +
  " WHERE SUBSTR(space, 1, " +
  prefix.length().to_string() +
  ") = " +
  dialect.placeholder(1) +
  text +
  " ORDER BY updated DESC, name"
}
