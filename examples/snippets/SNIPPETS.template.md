# Snippets

Short pieces to copy into a program, one per feature. Each is a whole file (or a spec and body pair) that
compiles as it is, in a crate made by `alr init` (`examples/snippets/generate.sh` compiles every one before it
writes this page). The web ones are packages with a `Register` procedure, so they plug into the hello world of
[GETTING_STARTED.md](GETTING_STARTED.md):

```ada
Greetings.Register (Routes);   --  before Servers.Run
```

A handler is a procedure `(Request : Http_Request; Response : in out Http_Response)` declared in a package,
not inside a subprogram, so that its `'Access` can be kept by the router. Each crate's README has the details.

- [Routes, parameters and queries](#routes-parameters-and-queries)
- [A JSON API](#a-json-api)
- [Static files](#static-files)
- [HTTPS and HTTP/2](#https-and-http2)
- [Passwords](#passwords)
- [Sessions, login and CSRF](#sessions-login-and-csrf)
- [Bearer tokens (JWT)](#bearer-tokens-jwt)
- [SQLite, one connection per worker](#sqlite-one-connection-per-worker)
- [PostgreSQL](#postgresql)
- [Templates](#templates)
- [Server-Sent Events](#server-sent-events)
- [WebSockets](#websockets)
- [File uploads](#file-uploads)
- [Rate limits and CORS](#rate-limits-and-cors)
- [Logs, metrics and health checks](#logs-metrics-and-health-checks)
- [Calling other services](#calling-other-services)
- [S3 object storage](#s3-object-storage)
- [Valkey: a cache, and sessions shared by several servers](#valkey-a-cache-and-sessions-shared-by-several-servers)
- [Tracing with OpenTelemetry](#tracing-with-opentelemetry)
- [Settings from the environment](#settings-from-the-environment)

## Routes, parameters and queries

Needs `sparrow_http`.

@include src/greetings.ads src/greetings.adb

`Parameter_Text`, `Query_Text` and `Form_Text` check that the value is UTF-8 and return text; `Parameter`,
`Query_Value` and `Form_Value` return the raw bytes. A `*name` segment (`/files/*path`) takes the rest of the
path.

## A JSON API

Needs `sparrow_http` (which brings `sparrow_json`).

@include src/bookmarks.ads src/bookmarks.adb

Reading nested values: `Integer_Value (Doc, "page.count", Default => 1)`, `Text (Doc, "items.0.title")`, and
`for Item in Json.Iteration.Elements (Doc, "items") loop ... Text (Doc, "title", From => Item) ...`.

## Static files

Needs `sparrow_http`.

@include src/site.ads src/site.adb

`ETag`, 304, byte ranges (video seeking, resumed downloads), gzip and `app.js.gz` siblings come with it.
Paths that climb out of the folder are refused.

## HTTPS and HTTP/2

Needs `sparrow_http`. A certificate for local work:
`openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj /CN=localhost -keyout key.pem -out cert.pem`.

@include src/secure_hello.adb

Browsers pick HTTP/2 on their own; handlers do not change. `curl -k --http2 https://localhost:8080/hello/you`.

## Passwords

Needs `sparrow_crypto`. Argon2id, with the salt and cost kept in the stored string.

@include src/password_hashes.ads src/password_hashes.adb

Hashing takes tens of milliseconds by design: do it in handlers on workers (the default). After a successful
login, `Passwords.Needs_Rehash (Stored)` says when to store a fresh hash.

## Sessions, login and CSRF

Needs `sparrow_http`. The session is sealed into a cookie (AES-256-GCM); the server keeps nothing.

@include src/accounts.ads src/accounts.adb

Scripts send the token in an `X-CSRF-Token` header instead (`Sessions.Csrf_Token (Session)`). To keep sessions
on the server, use `Sessions.Table_Store` with a `Session_Table` (see the Valkey snippet).

## Bearer tokens (JWT)

Needs `sparrow_jwt`. HS256 with a shared secret; `Sparrow.Jwt.Key_Sets` verifies RS256, ES256 and EdDSA
tokens against another service's JWKS.

@include src/api_tokens.ads src/api_tokens.adb

## SQLite, one connection per worker

Needs `sparrow_sqlite`. Each worker task opens its own connection at start: no pool, no locks.

@include src/todo_store.ads src/todo_store.adb

```ada
Servers.Run (Servers.From_Environment, Routes, Hooks => Todo_Store.Hooks);
```

## PostgreSQL

Needs `sparrow_postgres`. Statements are prepared once per connection; parameters are typed and sent in binary.

@include src/user_queries.ads src/user_queries.adb

In a server, keep one connection per worker: an `array (Worker_Id) of access Connection` filled by the
`On_Start` worker hook, as `examples/notes_api` does.

## Templates

Needs `sparrow_templates`. Mustache: `{{name}}` escaped, `{{{name}}}` raw, `{{#list}}...{{/list}}`.

@include templates/articles.mustache

@include src/article_pages.ads src/article_pages.adb

`Sparrow.Templates.Bindings.Add_Rows` turns an SQLite statement's rows into a list in one call, and
`Sparrow.Templates.Json_Data` renders straight from a JSON document.

## Server-Sent Events

Needs `sparrow_http`. One response that stays open; the server pushes events to it from any task.

@include src/price_feed.ads src/price_feed.adb

Closed connections drop out of the group by themselves; a client that falls too far behind is disconnected.

## WebSockets

Needs `sparrow_http`. A chat room: every message goes to everyone connected.

@include src/chat.ads src/chat.adb

Only pages from the same host may connect; `Serve (..., Allowed_Origins => "https://app.example")` allows others.

## File uploads

Needs `sparrow_http`. A `multipart/form-data` form, held in memory up to the body limit (1 MiB by default).

@include src/avatars.ads src/avatars.adb

For files of any size, add the route with `Body_Mode => Streamed` and use `Multipart.Save_Stream`, which
writes each file to disk as it arrives (see `examples/file_drop`).

## Rate limits and CORS

Needs `sparrow_http`.

@include src/guarded.ads src/guarded.adb

Behind a proxy, set `BEHIND_PROXY=on` so the client is read from `X-Forwarded-For`. For limits counted
across several servers, see the Valkey snippet.

## Logs, metrics and health checks

Needs `sparrow_http`. Every request is already logged (one access-log line, with its request id), counted and
timed; this adds your own.

@include src/shop.ads src/shop.adb

`LOG_FORMAT=json` writes JSON lines for log collectors. Outside a request, use `Sparrow.Logs.Info (...)`.
Keep `/metrics` off the public side of a load balancer.

## Calling other services

Needs `sparrow_client`.

@include src/weather.ads src/weather.adb

`Sparrow.Client.Post (Url, Content, Answer, Media_Type => ...)` sends a body. Calls block: make them from
handlers on workers.

## S3 object storage

Needs `sparrow_s3`. Works with AWS and with compatible stores (MinIO, R2, Garage, ...).

@include src/photos.ads src/photos.adb

`S3.Presigned_Put` lets the browser upload straight to the store, so large files never pass through the server.

## Valkey: a cache, and sessions shared by several servers

Needs `sparrow_valkey`. Speaks to Valkey or Redis; no C library.

@include src/shared_state.ads src/shared_state.adb

## Tracing with OpenTelemetry

Needs `sparrow_open_telemetry`. Each request becomes a span; spans go to an OpenTelemetry collector over OTLP.

@include src/traced_hello.adb

Inside a handler, `Spans.Start (Request, "load user")` adds a span of your own, ended with its block.

## Settings from the environment

`Servers.From_Environment` reads:

| Variable | Default | Meaning |
|---|---|---|
| `HOST` | `127.0.0.1` | Address to listen on: `0.0.0.0` for every IPv4 interface, `::` for IPv4 and IPv6 |
| `PORT` | `8080` | Port |
| `REACTORS` | one per processor | Tasks that own the connections |
| `WORKERS` | `8` | Tasks that run handlers which may block |
| `ACCESS_LOG` | `on` | One log line per request |
| `TRUST_TRACE` | `on` | Keep the `X-Request-Id` and `traceparent` a request arrives with; `off` when clients reach the server directly |
| `BEHIND_PROXY` | `off` | Read the client's address from `X-Forwarded-For` (only when every request comes through the proxy) |
| `HTTP_2` | `on` | HTTP/2 by prior knowledge over plain TCP (over TLS, ALPN chooses) |
| `COMPRESSION` | `on` | gzip for responses worth compressing |

Logging (`Sparrow.Logs`) reads `LOG_LEVEL` (`info`) and `LOG_FORMAT` (`text`, or `json` for log collectors).
Or build a `Servers.Configuration` in code and pass it to `Servers.Run`.
