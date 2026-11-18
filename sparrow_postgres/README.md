# sparrow_postgres

A PostgreSQL client over the system's libpq (16 or later). libpq handles the protocol, authentication, TLS
and host failover. This crate adds typed statements, parameters built in place, binary results, and
pipelining. The value decoders (`Sparrow.Postgres_Wire`) are proved free of run-time errors.

```toml
[[depends-on]]
sparrow_postgres = "~0.1.0-dev"
```

A program built against an older libpq refuses to start and says what to update.

## Connecting

```ada
Db : Postgres.Connection;
...
Postgres.Connect (Db, "postgresql://app@db.example/app?sslmode=verify-full");
```

Any libpq URL or keyword string works. The session uses UTF-8, so text is `UTF8_String` both ways. With
`sslmode=verify-full` and no `sslrootcert`, the system's trust store is used.

A connection belongs to one task and blocks. In a server, give each worker its own (see
`Sparrow.Http.Servers.Worker_Hooks`).

## Statements

```ada
use Sparrow.Postgres.Queries;
Find_User : aliased constant Postgres.Statement :=
  Postgres.Define ("find_user", "SELECT id, name FROM users WHERE email = $1 LIMIT $2");
...
Postgres.Prepare (Db, Find_User);                   --  once per connection

Query (Db, Find_User, [+Email, +Limit], Result);
for Row in Rows (Db, Result) loop
   Show (Row.Integer_Value ("id"), Row.Text ("name"));
end loop;
```

- The server infers each parameter's type, and `Prepare` asks it for them. Give `Parameter_Types` (or cast
  in SQL, `$1::int8`) only where the SQL leaves a type open.
- Parameters (`+` or `Bytes`, `Timestamp`, `Null_Value`): text and JSON, integers, booleans, floats,
  `bytea`, `timestamptz`, `NULL`.
- Columns are named as the query names them (use `AS` for expressions) or numbered from 1. Values read as
  text, bytes, integer, boolean, float or timestamp; arrays through `Field` and `Element`.
- `Result.Succeeded` and `Result.State` report a statement the server refused; `Last_Failure` says why.
- `Queries.Result_Reader` reads a result row by row, every value as text, for
  `Sparrow.Templates.Bindings.Add_Rows`. `Column_Name` and `Column_Type` describe a result's columns.

## Migrations

```ada
Postgres.Migrations.Apply (Db, Steps);   --  a Sparrow.Migrations.Step_List, before Prepare
```

Pending steps run in one transaction holding an advisory lock, so servers starting together apply each
once; a failing step raises `Migration_Error`, naming it, and leaves the database as it was. Versions are
recorded in `schema_migrations`. The same `Step_List` works with `sparrow_sqlite`.

## Pipelines

Underneath `Query`: `Bind`, `Add_Parameter`, `Execute` any number of statements, `Sync`, `Flush` once, then `Read_Results` once per `Sync`. A
whole group travels in one round trip. A statement the server rejects is a result that did not succeed,
not an exception. `Connection_Error` is raised only for a broken connection.

`Run_Script` runs fixed SQL text; the last statement's rows come back as text. Never put input in it;
use parameters.

MIT licensed.
