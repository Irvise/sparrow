# sparrow_valkey

A client of [Valkey](https://valkey.io) (and of Redis, which speaks the same protocol), and a place for what
every server behind a load balancer must share: the sessions of `Sparrow.Http.Sessions` and the buckets of
`Sparrow.Http.Limits`. Those implement interfaces of `sparrow_core` (`Sparrow.Stores`), so this crate does
not depend on `sparrow_http`: a worker that only uses Valkey as a cache or queue builds no server code.

```toml
[[depends-on]]
sparrow_valkey = "~0.1.0-dev"
```

## Sessions in Valkey

One line moves a table store's sessions there:

```ada
Visitors : constant Sessions.Store :=
  Sessions.Table_Store (Valkey.Sessions.Table (Environment ("VALKEY_URL")));
```

The cookie then holds only a random id. Each session is a key (`sparrow:session:<id>`) that Valkey expires on
its own, and each signed-in user has a set of their session ids (`sparrow:user:<user>`), so `Revoke_User`
ends all of them in one atomic call. `Prefix` keeps applications that share a server apart; `Connections`
(default 8) is how many calls can run at once.

The table opens its connections as first needed, lends one to each call, and opens a new one when the old one
was lost (Valkey restarted, or closed an idle connection). Handlers that load or save these sessions wait on
the network, so run them on workers. When Valkey cannot be reached, loading or saving raises
`Connection_Error`, and the request gets a 500.

## Rate limits in Valkey

```ada
Logins : constant Limits.Limit :=
  Limits.Per_Client (0.2, 5, Store => Valkey.Limits.Buckets (Environment ("VALKEY_URL"), Name => "logins"));
```

Every server then draws from the same buckets. Each bucket is a small hash that one script refills and takes a
token from, atomically and by Valkey's clock, and that expires once it would be full again. `Name` keeps one
limit's buckets apart from another's: give each limit its own.

A limited request waits for one round trip, so run limited routes on workers. When Valkey cannot be reached,
requests are let through and a warning is logged (at most every ten seconds): a cache outage should not lock
everyone out.

## Other shared counters

Counters that decide something (allow, refuse, run) need the same answer on every server, so they belong in
Valkey:

| Need | Call |
|---|---|
| A quota: 1000 calls an hour | `Increment (Cache, "calls:" & Key, Lifetime => 3600) > 1000` (the hour starts at the first call) |
| Lock an account after failed logins | The same, keyed by account |
| Run once (an idempotency key, a webhook seen before) | `Set_If_Absent (Cache, "seen:" & Id, "1", Lifetime => 86_400)` |
| A short lock: one server runs the nightly job | `Set_If_Absent (Cache, "lock:nightly", Server_Name, Lifetime => 600)` |

Metrics are not among them: each server exports its own `/metrics`, and Prometheus adds them up.

## The client

A connection belongs to one task and blocks: give each worker its own (`Servers.Worker_Hooks`), as with
`sparrow_postgres`.

```ada
Cache : Valkey.Connection;
...
Valkey.Connect (Cache, Valkey.Server_At (Environment ("VALKEY_URL")));
Valkey.Set (Cache, "page:/", Html, Lifetime => 60);
... Valkey.Get (Cache, "page:/", Default => "") ...
Hits := Valkey.Increment (Cache, "hits");
```

| URL | Meaning |
|---|---|
| `valkey://localhost` | Port 6379, no password, database 0 |
| `valkey://:secret@cache:6380/2` | A password (percent-encoded), port 6380, database 2 |
| `valkey://app:secret@cache` | A user of Valkey's access lists, and their password |
| `valkeys://...` | The same over TLS; `Trust_File` names root certificates other than the system's |

`redis://` and `rediss://` mean the same. `Connect` signs in, selects the database (or sends a `PING`), so a
wrong password or an unreachable server shows at once. A host name is tried at each of its addresses in turn.

The helpers `Get`, `Set`, `Set_If_Absent`, `Delete`, `Exists`, `Increment` (also with a `Lifetime`, set
together with the first increment) and `Expire` raise `Command_Error` when the server refuses the command. Any other command is built with `Start` and `Add`. Commands started before a
`Read_Reply` go out together, and their replies come back in order, so a thousand commands cost one round
trip:

```ada
for Page of Pages loop
   Valkey.Start (Cache, "HINCRBY"); Valkey.Add (Cache, "views"); Valkey.Add (Cache, Page); Valkey.Add (Cache, 1);
end loop;
for Page of Pages loop
   Valkey.Read_Reply (Cache, Answer);   --  Kind (Answer) = Number, or Error
end loop;
```

A reply is `Status`, `Error`, `Number`, `Text` (any bytes), `Nil` or a `List` of replies (`Count`, `Item`). It
can be read until the next `Read_Reply`. A refused command gives an `Error` reply here, not an exception.

`Connection_Error` means there was no answer: the name did not resolve, the connection, TLS or the password
failed, the time ran out (`Timeout`, 5 s by default) or the server sent something that is not the protocol.
The connection is then closed; `Connect` it again to go on.

## Safety

The reply reader (`Sparrow.Valkey_Protocol`) is proved in SPARK: no reply, however malformed or cut short,
makes it raise or read outside its input. Replies are limited to a million elements and strings to 512 MiB,
Valkey's own limit. It is also fuzzed (`tests/fuzz`, target `valkey_replies`).

## Tests

`tests/valkey_server.sh` starts a throwaway Valkey 9 in a container (plain and TLS, with a password); the
tests skip themselves when it is not running.
