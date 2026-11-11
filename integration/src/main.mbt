// Runs the checkpoint scenarios against the in-memory saver and the SQL backends,
// and fails when two of them disagree. SQLite is always on; PostgreSQL and MySQL
// are required once `MOONSTATE_LIVE` is set, and a connection that does not open
// is a failure then — a backend that silently skips is a backend that always
// passes.

///|
fn env_or(name : String, fallback : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => value
    None => fallback
  }
}

///|
fn env_int(name : String, fallback : Int32) -> Int32 {
  match @env.get_env_var(name) {
    Some(text) => {
      let parsed = @json.parse(text) catch { _ => Json::null() }
      match parsed {
        Number(value, ..) => value.to_int()
        _ => fallback
      }
    }
    None => fallback
  }
}

///|
fn transcript_of(lines : Array[String]) -> String {
  let out = StringBuilder()
  for line in lines {
    out.write_string(line)
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// Whether the two transcripts agree, printing the first line that differs when
/// they do not.
fn compare(
  backend : String,
  reference : Array[String],
  other : Array[String],
) -> Bool {
  let mut index = 0
  while index < reference.length() && index < other.length() {
    if reference[index] != other[index] {
      println(
        backend +
        " differs from memory at line " +
        (index + 1).to_string() +
        ":\n  memory: " +
        reference[index] +
        "\n  " +
        backend +
        ": " +
        other[index],
      )
      return false
    }
    index = index + 1
  }
  if reference.length() != other.length() {
    println(
      backend +
      " differs from memory in length: " +
      reference.length().to_string() +
      " against " +
      other.length().to_string(),
    )
    return false
  }
  true
}

///|
/// Every line of the conformance transcript carries an expected value, so a
/// backend that agrees with another while both are wrong still fails here.
fn failed_cases(backend : String, lines : Array[String]) -> Int32 {
  let mut count = 0
  for line in lines {
    if line.has_prefix("FAIL ") {
      println(backend + ": " + line)
      count = count + 1
    }
  }
  count
}

///|
async fn main {
  let mut failures = 0
  println("start")
  let reference = suite(
    @moonstate.MemorySaver::new(),
    @moonstate.MemoryStore::new(),
  )
  println("memory")
  println(transcript_of(reference))
  let reference_cases = conformance_suite(@moonstate.MemorySaver::new())
  println(transcript_of(reference_cases))
  failures = failures + failed_cases("memory cases", reference_cases)
  let stamp = @env.now().to_string()
  let directory = match @env.get_env_var("TMPDIR") {
    Some(path) => path
    None => env_or("TEMP", ".")
  }
  let path = directory + "/moonstate-" + stamp + ".db"
  {
    let connection = @moonsqlite.SqliteDriver::open(path)
    let saver = @sql.saver(@sql.blocking(connection))
    let store = @sql.store(@sql.blocking(connection))
    // SQLite's driver does not number its parameters, so nothing needs saying.
    saver.setup()
    store.setup()
    let sqlite = suite(saver, store)
    println("sqlite")
    println(transcript_of(sqlite))
    if !compare("sqlite", reference, sqlite) {
      failures = failures + 1
    }
    let sqlite_cases = conformance_suite(saver)
    println(transcript_of(sqlite_cases))
    if !compare("sqlite cases", reference_cases, sqlite_cases) {
      failures = failures + 1
    }
    failures = failures + failed_cases("sqlite cases", sqlite_cases)
    connection.close()
  }
  let live = @env.get_env_var("MOONSTATE_LIVE") is Some(_)
  if live {
    let host = env_or("PGHOST", "127.0.0.1")
    let port = env_int("PGPORT", 5432)
    let user = env_or("PGUSER", "postgres")
    let password = env_or("PGPASSWORD", "postgres")
    let database = env_or("PGDATABASE", "postgres")
    let descriptor = @moonpostgres.PgDriver::new(
      host~,
      port~,
      user~,
      password~,
      database~,
    )
    let saver_connection = descriptor.connect()
    let store_connection = descriptor.connect()
    // Named rather than read off the connection: `moonpostgres` numbers its
    // parameters but does not report `Dialect::Postgres` yet, and a saver built
    // for the wrong dialect is rejected by the server at the first statement.
    let saver = @sql.saver(saver_connection, dialect=@moondb.Dialect::Postgres)
    let store = @sql.store(store_connection, dialect=@moondb.Dialect::Postgres)
    saver.setup()
    store.setup()
    let postgres = suite(saver, store)
    println("postgres")
    println(transcript_of(postgres))
    if !compare("postgres", reference, postgres) {
      failures = failures + 1
    }
    let postgres_cases = conformance_suite(saver)
    println(transcript_of(postgres_cases))
    if !compare("postgres cases", reference_cases, postgres_cases) {
      failures = failures + 1
    }
    failures = failures + failed_cases("postgres cases", postgres_cases)
    saver_connection.close()
    store_connection.close()
    let mysql_host = env_or("MYSQL_HOST", "127.0.0.1")
    let mysql_port = env_int("MYSQL_TCP_PORT", 3306)
    let mysql_user = env_or("MYSQL_USER", "root")
    let mysql_password = env_or("MYSQL_PWD", "moonstate")
    let mysql_database = env_or("MYSQL_DATABASE", "moonstate")
    let mysql_saver = @client.MysqlConn::connect(
      mysql_host, mysql_port, mysql_user, mysql_password, mysql_database,
    )
    let mysql_store = @client.MysqlConn::connect(
      mysql_host, mysql_port, mysql_user, mysql_password, mysql_database,
    )
    let saver = @sql.saver(mysql_saver, dialect=@moondb.Dialect::Mysql)
    let store = @sql.store(mysql_store, dialect=@moondb.Dialect::Mysql)
    saver.setup()
    store.setup()
    let mysql = suite(saver, store)
    println("mysql")
    println(transcript_of(mysql))
    if !compare("mysql", reference, mysql) {
      failures = failures + 1
    }
    let mysql_cases = conformance_suite(saver)
    println(transcript_of(mysql_cases))
    if !compare("mysql cases", reference_cases, mysql_cases) {
      failures = failures + 1
    }
    failures = failures + failed_cases("mysql cases", mysql_cases)
    mysql_saver.close()
    mysql_store.close()
  } else {
    println("postgres and mysql: skipped, set MOONSTATE_LIVE to require them")
  }
  @fs.remove(path)
  if failures > 0 {
    println("the backends disagree: " + failures.to_string())
    @env.exit(1)
  }
  println("every backend answers alike")
}
