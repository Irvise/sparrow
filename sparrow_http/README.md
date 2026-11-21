# sparrow_http

A non-blocking HTTP/1.1 and HTTPS server with a router. It also has static files, streaming responses,
Server-Sent Events, WebSockets, sealed-cookie sessions with CSRF tokens, CORS, multipart uploads, request
ids with W3C trace context, and an access log.

```toml
[[depends-on]]
sparrow_http = "~1.0.0"
```

## A server

```ada
--  hello_pages.ads: handlers live in a library-level package, so routes take 'Access
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Hello_Pages is
   procedure Greet (Request : Http_Request; Response : in out Http_Response);
end Hello_Pages;

--  hello_pages.adb
with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;

package body Hello_Pages is
   procedure Greet (Request : Http_Request; Response : in out Http_Response) is
   begin
      Responses.Send (Response, OK, "Hello, " & Requests.Parameter_Text (Request, "name"));   --  UTF8_String "&"
   end Greet;
end Hello_Pages;

--  hello.adb
with Hello_Pages;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;

procedure Hello is
   Routes : Router (Capacity => 8);
begin
   Add (Routes, Get, "/hello/:name", Hello_Pages.Greet'Access);
   Sparrow.Http.Servers.Run (Sparrow.Http.Servers.From_Environment, Routes);   --  until Ctrl-C or SIGTERM
end Hello;
```

`From_Environment` reads `HOST`, `PORT`, `REACTORS`, `WORKERS`, `ACCESS_LOG`, `TRUST_TRACE`,
`BEHIND_PROXY` and `HTTP_2`. Pass `Security => Certificate'Access` (a `Sparrow.Tls` server context) to serve HTTPS.

A handler is told where and when it runs through its request: `Requests.Worker (Request)` (index per-worker
state with it), `Requests.Now`, `Requests.Connection` (to send to later) and `Requests.Trace`.

`HOST` is an address of either family:
- `127.0.0.1`, the default: this machine only.
- `0.0.0.0`: every IPv4 interface.
- `::`: every interface, IPv4 and IPv6 (dual stack).
- `::1`, or any other address of one interface.

With `BEHIND_PROXY=on`, the client (in the access log, in `Requests.Client_Address`, and for rate limits) is
the last `X-Forwarded-For` entry, IPv6 included.

### HTTP/2

Sparrow serves HTTP/2 (RFC 9113) as well as HTTP/1.1, on the same port. Framing, HPACK header compression
and flow control are written in Ada and proved free of run-time errors, like the HTTP/1.1 parser; no C
protocol library is involved.

- **Over TLS,** clients choose HTTP/2 by ALPN (`h2`). Browsers do. `Tls.Open_Server (..., Offer_Http_2 =>
  False)` keeps a server on HTTP/1.1.
- **Over plain TCP,** a client that knows the server speaks HTTP/2 may start with its preface ("prior
  knowledge", as `curl --http2-prior-knowledge` and gRPC-style clients do). `Http_2 => False` in the
  configuration, or `HTTP_2=off`, turns that off. `Upgrade: h2c` is not supported (RFC 9113 deprecates it).
- **Handlers do not change.** A request reaches its handler in the same form whatever the protocol, and
  responses, `Streams`, event streams and streamed bodies work the same way over both. WebSockets stay on
  HTTP/1.1 (WebSockets over HTTP/2, RFC 8441, is not offered, so browsers open an HTTP/1.1 connection for
  them).
- **Limits:**
  - 100 streams per connection;
  - header blocks bounded by `Max_Head_Length`, and bodies by `Max_Body_Length` (streamed ones by the window);
  - flow-control windows of 256 KiB per stream and 16 MiB per connection;
  - floods of reset streams (CVE-2023-44487) and of CONTINUATION frames (CVE-2024-27316) end the
    connection.

  There is no server push and no prioritisation.

### Behind a proxy

A TLS-terminating proxy in front (nginx, Envoy, Caddy, a cloud load balancer) still works: it can speak
HTTP/2 or HTTP/3 to browsers and either protocol to Sparrow. Run Sparrow with `BEHIND_PROXY=on` there, and
only there: it trusts `X-Forwarded-For`, so clients must not be able to reach Sparrow directly.

## How it runs

- **Reactors** (one per processor by default) own the connections. They accept, run TLS, read, parse,
  route and write.
- **Workers** (a pool) run handlers that may block: databases, password hashing, outbound calls.
- Each route chooses where its handler runs: `On_Worker` (the default) or `On_Reactor` (for handlers that
  only compute and never block).
- `Worker_Hooks` run on each worker as it starts and stops. Use them to keep one database connection per
  worker, with no pool and no locks.
- On shutdown, requests in flight are drained (up to 30 s). Idle connections and stalled TLS handshakes
  time out.

Limits (head 16 KiB, body 1 MiB, streamed body 16 GiB, 64 headers, connections, queue) live in
`Configuration`. A request body may come with a `Content-Length` or chunked; other transfer codings get 501.

## Request bodies

By default a route's body is read whole, then the handler runs: `Requests.Content`, `Json_Body`,
`Form_Value`. A chunked body arrives decoded. Bodies past `Limits.Max_Body_Length` get 413.

For uploads larger than memory should hold, add the route with `Body_Mode => Streamed`. Its handler runs
as soon as the head arrives and reads the body as it comes, with `Sparrow.Http.Bodies`:

```ada
procedure Upload (Request : Http_Request; Response : in out Http_Response) is
   Part : String (1 .. 65_536);
   Last : Natural;
begin
   loop
      Bodies.Read (Request, Part, Last);
      exit when Last < Part'First;   --  the end
      ...                            --  write Part (1 .. Last) somewhere
   end loop;
   Responses.Send (Response, Created, "stored");
end Upload;
...
Add (Routes, Post, "/upload", Upload'Access, Body_Mode => Streamed);
```

- **Back-pressure.** While the handler does not read, the server stops reading the socket. At most 128 KiB
  of an upload wait in the server.
- **Limits.** A streamed body may be as long as `Limits.Max_Streamed_Length` (16 GiB). The buffered limit
  still applies to every other route, and is checked before their body arrives.
- **Failures.** `Bodies.Read` raises `Body_Error` when the client leaves, sends a malformed chunked body, or
  passes the limit. An upload that stalls for `Idle_Timeout` is cut off the same way.
- **Answering early.** A handler may answer before reading everything (a refusal, say); the connection is
  then closed after the response.
- `Bodies.Read_All` reads a streamed body that turns out small; `Bodies.Declared_Length` gives the
  `Content-Length` (-1 when chunked).

## Packages

| Package | What it does |
|---|---|
| `Sparrow.Http` | Methods, status codes, media types, `Connection_Id`, `Trace_Context` |
| `.Routers` | Routes (`/articles/:slug`, `/static/*file`) to handler procedures or `Route_Handler` objects |
| `.Requests` | Method, path, query, headers, cookies, form fields, `Json_Body`; checked-text and integer helpers |
| `.Responses` | `Send`, `Send_Bytes`, `Fail`, `Redirect`, `Set_Header`, `Set_Cookie`, `Begin_Content`, `Begin_Stream` |
| `.Servers` | `Run`, `Stop`, `Configuration`, `From_Environment` |
| `.Static` | Files from a folder: media types, `ETag`/`Last-Modified`/304, ranges (206/416), `file.gz` siblings, `index.html`, path traversal refused |
| `.Compression` | gzip for responses that are worth it; `Accepts_Gzip`, `Compressible` (proved) |
| `.Ranges` | The `Range` header: one byte range (proved) |
| `.Streams` | Send to a connection later, from any task; `Group` for broadcasting |
| `.Event_Streams` | Server-Sent Events (`text/event-stream`) with a heartbeat |
| `.Websockets` | WebSocket endpoints (RFC 6455): handshake, framing, pings, origin check |
| `.Sessions` | Sessions in a sealed cookie or a server-side table; CSRF tokens |
| `.Bodies` | Request bodies read as they arrive (`Body_Mode => Streamed`) |
| `.Limits` | Rate limits: a token bucket per client or key, 429 with `Retry-After` |
| `.Cors` | A CORS policy: preflight handler and response headers |
| `.Multipart` | `multipart/form-data` fields and files |
| `.Log` | Logging with the request's id; trace headers for outbound calls |
| `.Health` | `/healthz`, `/readyz` (with your check) and `/metrics` |
| `.Spans` | Spans of the request's trace, for an exporter (sparrow_open_telemetry) |
| `.Parser` | The HTTP/1.1 head parser (proved) |
| `.Http_2` | HTTP/2 framing, streams and flow control for one connection, as a state machine (proved) |
| `.Hpack` | HPACK header compression (RFC 7541) (proved) |
| `.Frames` | WebSocket frame heads and unmasking (proved) |
| `.Route_Patterns` | Route pattern checking, matching and captures (proved) |
| `.Multipart_Scanning` | Multipart delimiters, part headers and header parameters (proved) |
| `.Session_Envelope` | Reading a session's sealed text (proved) |

## JSON

```ada
procedure Create (Request : Http_Request; Response : in out Http_Response) is
   Fields : constant Json.Document := Requests.Json_Body (Request);   --  sized to the body
   Reply  : Json.Builders.Builder (Response.Content'Access);
begin
   if not Json.Is_Valid (Fields) then
      Responses.Send (Response, Bad_Request, "the body is not JSON");
      return;
   end if;
   ...
   Responses.Begin_Content (Response, Created, Application_Json);
   Reply.Begin_Object;
   Reply.Member ("id", Id);
   Reply.End_Object;
end Create;
```

`Json_Body` bounds the document by the body: never more nodes than values, never more text than bytes, and
the body itself is bounded by `Limits.Max_Body_Length`.

## Static files

```ada
Add (Routes, Get, "/static/*file", Static.Folder ("public", Max_Age => 3600));
```

- **Ranges.** `Range: bytes=0-499`, `bytes=500-` and `bytes=-500` get 206 with those bytes and
  `Content-Range`; a range past the end gets 416. This is what video seeking and resumed downloads use.
  `If-Range` naming another version gets the whole file. A request for several ranges gets the whole file, as
  RFC 9110 allows. Files over `Max_File_Size` (64 MiB) are still served in ranges, up to 64 MiB per response.
- **Precompressed files.** When the client takes gzip and `app.js.gz` sits beside `app.js`, the `.gz` file is
  sent as it is, with no work per request. Make them at build time (`gzip -9k`, or `zopfli` for smaller).
  Without one, text files are compressed per response like any other.

## Compression

Whole responses are gzip-compressed when the client's `Accept-Encoding` takes gzip and the response is worth
it. That means:
- a compressible `Content-Type` (`text/*`, JSON, JavaScript, XML, SVG, WebAssembly, `+json`, `+xml`);
- at least 1 KiB;
- a 2xx status other than 204 and 206;
- no `Content-Encoding` already, and no `Cache-Control: no-transform`.

It works the same for HTTP/1.1 and HTTP/2, on the task that ran the handler. Such responses get
`Vary: Accept-Encoding`, and a strong `ETag` becomes weak (`W/"…"`), since the bytes differ while the content
does not.

The compressor is `Sparrow.Gzip` in sparrow_core: DEFLATE written in Ada and proved, with no zlib. On text it
is about 5% larger than `gzip -6` and faster than it: about 75 MB/s per core on source code and logs, and a
4 KiB page in about 40 µs.

- **Turning it off.** `COMPRESSION=off`, or `Compression => False` in `Servers.Configuration`, when a proxy in
  front compresses.
- **One response as it is.** Set `Cache-Control: no-transform` on it.
- **BREACH.** Each gzip header carries 1–32 random bytes of padding. That makes guessing a secret from the
  compressed lengths of many responses harder; it does not make it impossible. A page that echoes request
  input next to a secret (a CSRF token) can set `no-transform`.

## Streams, Server-Sent Events, WebSockets

```ada
procedure Subscribe (Request : Http_Request; Response : in out Http_Response) is
begin
   Event_Streams.Begin_Events (Response);
   Streams.Add (Watchers, Requests.Connection (Request));
end Subscribe;
...
Event_Streams.Send (Watchers, "{""price"": 12}", Name => "price");   --  later, from any task
```

```ada
type Chat_Room is new Websockets.Endpoint with null record;
overriding procedure On_Message
  (This : Chat_Room; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context);
...
Add (Routes, Get, "/chat", Websockets.Serve (new Chat_Room));
...
Streams.Send (Socket, "hello");            --  from On_Message, or from any task
```

- What one task sends to one connection arrives in order.
- Sending to a closed connection does nothing.
- A client more than 8 MiB behind is disconnected.
- `On_Open` and `On_Close` can be overridden too.
- A socket's messages reach `On_Message` one at a time, in order. One endpoint object serves every socket,
  possibly from several tasks at once.
- An exception in `On_Message` closes the socket with code 1011.
- By default only pages from the same host may open a WebSocket.

## Sessions and CSRF

```ada
Visitors : constant Sessions.Store := Sessions.Cookie_Store (Secret => Environment ("SESSION_SECRET"));
...
Session : Sessions.Session := Visitors.Load (Request);
if Requests.Verb (Request) = Post and then not Sessions.Csrf_Valid (Session, Request) then
   Responses.Fail (Response, Forbidden);
   return;
end if;
Sessions.Set (Session, "user", "42");
Visitors.Save (Session, Response);
```

- A session is a small map of text values. Every session holds a CSRF token: `Csrf_Field` adds it to forms,
  and the `X-CSRF-Token` header carries it for scripts.
- Call `Renew` at login: it draws a new token (and, in a table, a new id).

Two stores:

- **`Cookie_Store`**: the session is sealed (AES-256-GCM) into one cookie. The browser can neither read nor
  change it, and the server keeps nothing. Keep it under about 4 KB.
  - **Rotating the secret:** pass the old one as `Previous_Secret`. Sessions sealed with it are still read,
    and sealed again with the new one when saved. Drop it after `Max_Age`.
  - **Ending sessions early:** keep a counter per user in your database. Store it in the session at login
    (`Set_Generation`) and check it on each request (`Check_Generation (Session, Stored)`, which logs out a
    session of an older generation). Adding one to a user's counter logs out all of that user's sessions.
- **`Table_Store (Table'Access)`**: the cookie holds only a random 256-bit id, and the session lives in a
  `Session_Table`.
  - Implement `Session_Table` over your database: one table of id, user, data and expiry, with `Read`,
    `Write`, `Delete` and `Delete_User`. The interface is declared in `Sparrow.Stores` (sparrow_core), so a
    table in a crate of its own need not depend on this one.
  - `Memory_Table` is a ready one, held in the process (for development and single servers).
  - For several servers, `sparrow_valkey` has a ready one in Valkey:
    `Table_Store (Valkey.Sessions.Table (Environment ("VALKEY_URL")))`.
  - `Revoke_User (User)` ends every session whose `"user"` value is `User`: log out everywhere, or ban.
  - `Max_Age` is an idle timeout: a session in use is written again once half of it has passed, not on
    every request.

## CORS and uploads

```ada
Api : constant Cors.Policy := Cors.Allow ("https://app.example");
...
Add (Routes, Options, "/api/*rest", Cors.Preflight (Api), On_Reactor);
Add (Routes, Get, "/api/items", Cors.Share (Api, List'Access));
```

`Multipart.Parse (Request, Upload, Valid)`, then `Field`, `Has_File`, `File_Name` and `Save`. Uploads are
held in memory, up to the body limit.

On a streamed route, `Multipart.Save_Stream (Request, Directory, Upload, Valid)` writes each file part to a
new file in `Directory`, named by Sparrow rather than the client, as it arrives. Fields are kept in memory,
up to `Max_Field_Length`. `Save` then moves a file where you want it, and `Discard` deletes the ones you did
not keep. A malformed body, or a client that leaves, deletes what was written.

## Rate limits

```ada
Logins : constant Limits.Limit := Limits.Per_Client (Rate => 0.2, Burst => 5);   --  then one every 5 s
...
Add (Routes, Post, "/login", Limits.Wrap (Logins, Log_In'Access));
```

- A token bucket per key: a client may send `Burst` requests at once, then `Rate` a second. Past that, the
  route answers 429 with `Retry-After`, counted in `sparrow_http_rate_limited_total`.
- `Per_Client` keys by `Requests.Client_Address`. `Per_Key` takes your own key function (an API key, the
  session's user). An empty key is not limited.
- One limit can wrap several routes: they draw from the same buckets.
- By default the buckets are in memory (`Memory_Buckets`), in 16 shards, each its own protected object. A
  bucket that has filled up again is forgotten once `Max_Keys` is reached, and failing that, the least
  recently used one. Each server counts on its own.
- To count across servers, pass a shared `Store`. sparrow_valkey has one:
  `Per_Client (0.2, 5, Store => Valkey.Limits.Buckets (Url, Name => "logins"))`. Any other store implements
  `Bucket_Store` (declared in `Sparrow.Stores`, sparrow_core), one `Take` procedure.

## Logging and tracing

Every request gets a request id, sent back as `X-Request-Id`. A valid incoming `X-Request-Id` or W3C
`traceparent` is kept. Every request gets one access-log line:

```
2026-11-17T14:21:55.123Z INFO    request request_id=4bf92f… method=GET path=/hello status=200 bytes=5 ms=0.015 client=127.0.0.1
```

```ada
Log.Info (Request, "bookmark saved", Log.Field ("id", Id));                  --  carries the request id
Client.Get (Url, Answer, Headers => Log.Trace_Headers (Request));            --  carries the trace onward
```

Exceptions that leave handlers are logged with the same id, and the client gets a 500. Use `LOG_FORMAT=json`
for log collectors. See `Sparrow.Logs` in sparrow_io.

## Health, metrics and traces

```ada
Health.Add (Routes, Check => Database_Ready'Access);   --  /healthz, /readyz, /metrics
```

- `/healthz` answers 200 while the process serves.
- `/readyz` answers 503 once the server is stopping (so a load balancer drains it), or when your check says
  no. A check runs on a worker, so it may ask the database.
- `/metrics` serves every `Sparrow.Metrics` metric in the Prometheus text format, including the server's own:

| Metric | Labels |
|---|---|
| `sparrow_http_requests_total` | `method`, `route` (the pattern), `status` (`2xx` ...) |
| `sparrow_http_request_duration_seconds` | `method`, `route`: a histogram from parsed request to response |
| `sparrow_http_connections` | `mode`: `http`, `stream`, `websocket` |
| `sparrow_http_queue_depth` | requests and messages waiting for a worker |
| `sparrow_http_rejected_total` | requests (503) and messages (1013) refused because the queue was full |
| `sparrow_http_refused_connections_total` | connections refused because every slot was taken |
| `sparrow_http_slow_clients_dropped_total` | streams and WebSockets closed for falling behind |
| `sparrow_http_websocket_messages_total` | `direction`: `in`, `out` |

`/metrics` shows which routes exist and how busy they are. Keep it off the public side, or route
`Health.Metrics` yourself behind authentication.

Each request is a span of its trace. Handlers add spans of their own:

```ada
declare
   Lookup : constant Spans.Span := Spans.Start (Request, "load user");   --  ends with the block
begin
   Client.Get (Url, Answer, Headers => Log.Trace_Headers (Spans.Context (Lookup)));
end;
```

Spans go nowhere until an exporter is set. sparrow_open_telemetry sets one that sends them to an
OpenTelemetry collector.

## Proof

Everything that reads a client's bytes is proved free of run-time errors (SPARK silver):
- the HTTP/1.1 parser, requests and responses;
- HTTP/2 and HPACK;
- WebSocket frames;
- route matching;
- multipart scanning;
- the session envelope;
- `Accept-Encoding` and `Range`.

The gzip compressor (sparrow_core) is proved too, and fuzzed against zlib's decoder.

The parsers are also fuzzed (`tests/fuzz`). The server's tasks and queues are tested, not proved, and run
under ThreadSanitizer (`tests/race.sh`).

MIT licensed.
