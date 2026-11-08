# moonstate-ecosystem

One workspace, one program: the checkpoint scenarios in `src/suite.mbt` are run
against the in-memory saver and against the SQL backends, and the transcripts are
compared line by line. A difference is a failure with exit code 1, not a note in a
log.

## Running it

```sh
cd integration
moon run src --target native
```

That runs the in-memory saver and SQLite, which needs nothing installed: the
database is a file in the system temporary directory, removed on the way out.

PostgreSQL and MySQL are opt-in, and required once the switch is set:

```sh
MOONSTATE_LIVE=1 PGPORT=5432 PGDATABASE=moonstate \
MYSQL_TCP_PORT=3306 MYSQL_DATABASE=moonstate MYSQL_PWD=moonstate \
moon run src --target native
```

The variables it reads are the ones the official clients read: `PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD`, `PGDATABASE`, `MYSQL_HOST`, `MYSQL_TCP_PORT`,
`MYSQL_USER`, `MYSQL_PWD`, `MYSQL_DATABASE`. `MOONSTATE_LIVE` unset means the two
remote backends are skipped with a line saying so.

## Why it is a module of its own

The library does not depend on a driver, and this program depends on four. Keeping
it here means the module a user downloads carries none of them, and that this runs
wherever a database is reachable rather than wherever the library compiles.
