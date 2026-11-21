# sparrow_sqlite

A thin binding to the system's libsqlite3: open, prepare, bind, step, read. Statements and databases release
themselves when they go out of scope, so a handler that raises leaks nothing.

```toml
[[depends-on]]
sparrow_sqlite = "~1.0.0"
```

```ada
Db   : Sqlite.Database;
Find : Sqlite.Statement;
...
Sqlite.Open (Db, "app.db");                 --  WAL, synchronous=NORMAL, foreign keys on, a busy timeout
Sqlite.Prepare (Db, Find, "SELECT id, name FROM users WHERE email = ?1");
Sqlite.Bind (Find, 1, Email);
for Row in Sqlite.Rows (Find) loop
   Show (Row.Integer_Value ("id"), Row.Text ("name"));
end loop;
```

- Parameters are numbered from 1. Columns are named as the `SELECT` names them (use `AS` for expressions)
  or numbered from 1; an unknown name raises `Database_Error`.
- `Rows` steps the statement; `Next_Row` with `Text (Find, "name")` does the same by hand.
- `TEXT` goes in as `UTF8_String`. Coming out, `Text` checks it is UTF-8 and raises `Database_Error` if it
  is not; `Bytes` reads it regardless.
- Errors raise `Database_Error` with SQLite's message. A refused `UNIQUE`, `NOT NULL`, `CHECK` or
  `FOREIGN KEY` raises `Constraint_Violation`, which you can catch to say "that name is taken".
- `Begin_Transaction`, `Commit`, `Rollback`, `Last_Insert_Id`, `Changes`.
- `Run_Script` runs fixed SQL text. Never put input in it.

## Migrations

The schema is a list of steps, applied once each and recorded in a `schema_migrations` table:

```ada
Steps : constant Sqlite.Migrations.Step_List :=
  [Sqlite.Migrations.Step (1, "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL UNIQUE)"),
   Sqlite.Migrations.Step (2, "ALTER TABLE users ADD COLUMN name TEXT NOT NULL DEFAULT ''")];
...
Sqlite.Migrations.Apply (Db, Steps);
```

Pending steps run in one `BEGIN IMMEDIATE` transaction: programs starting together apply each step once,
and a failing step (`Database_Error`, naming it) leaves the database as it was. Add steps; never edit one
that has run. The same `Step_List` works with `sparrow_postgres`.

## One connection per worker

A database connection belongs to one task, and SQLite calls block, so in a server each worker gets its own:

```ada
package Databases is new Sqlite.Per_Worker (Worker_Id, Path => "app.db", Steps => Steps);
...
Servers.Run (Config, Routes, Hooks => (Databases.Open'Access, Databases.Close'Access));
...
Prepare (Databases.Connection (Requests.Worker (Request)), Find, "...");     --  in a handler
```

Opening is serialized, and the first worker applies the migrations before the others open.

MIT licensed.
