# sparrow_io

The operating system as Sparrow sees it: TCP sockets, readiness events, clocks, the environment, and
structured logging. One portable spec, one body per platform:

| Platform | Readiness events | Waker |
|---|---|---|
| Linux | epoll | eventfd |
| macOS, FreeBSD | kqueue | a pipe |
| Windows | WSAPoll | a loopback socket pair |

The Linux body is tested. The BSD and Windows bodies compile but have not run yet. The specs are SPARK, so
proved code can call them; the bodies are thin system calls. Nothing here raises: failures come back as
`Error` values (`Would_Block`, `Interrupted`, `Out_Of_Descriptors`, ...).

```toml
[[depends-on]]
sparrow_io = "~1.0.0"
```

## Packages

| Package | What it does |
|---|---|
| `Sparrow.IO` | `Descriptor`, `Error`, `Milliseconds` |
| `Sparrow.IO.Addresses` | IPv4 and IPv6 addresses: parsing any RFC 4291 form (brackets too), RFC 5952 `Image`, mapped addresses (proved) |
| `Sparrow.IO.Sockets` | TCP over IPv4 and IPv6 (a listener on `::` takes both families): listeners (optionally with shared ports), non-blocking `Accept_Client` (with the client's address), blocking `Connect` with a timeout, `Send`, `Receive`, `Resolve`, address parsing and `Image` |
| `Sparrow.IO.Events` | `Poller` (watch descriptors, wait for readiness) and `Waker` (wake a poller from another task) |
| `Sparrow.IO.Process` | Wall and monotonic clocks, `Environment`, `Sleep`, processor count, descriptor limits, signals, `Log` (one whole line to stderr) |
| `Sparrow.Logs` | Structured logging: levels, typed fields, text or JSON lines, replaceable sink |
| `Sparrow.Metrics` | Counters, gauges and histograms on atomic integers, in the Prometheus text format |

## Readiness events

```ada
Watch (Loop_One, Listener, (Readable => True, Writable => False));
Wait (Loop_One, Found, Count, Timeout => 1000);
for Index in 1 .. Count loop
   --  read or write Found (Index).Socket until Would_Block
end loop;
```

epoll and kqueue report changes, WSAPoll reports states. Code that reads (or writes) until `Would_Block` and
then waits, and tolerates empty events, is right under both. `Reports_Changes` tells which kind you have.

## Logging

```ada
Logs.Info ("cache warmed", Logs.Field ("entries", 1_200), Logs.Field ("source", "disk"));
```
```
2026-11-17T14:21:55.123Z INFO    cache warmed entries=1200 source=disk
{"time":"2026-11-17T14:21:55.123Z","level":"info","message":"cache warmed","entries":1200,"source":"disk"}
```

- `LOG_LEVEL` (`debug`, `info`, `warning`, `error`) and `LOG_FORMAT` (`text`, `json`) are read at start-up;
  `Configure` changes them.
- Fields: text, `Long_Long_Integer`, `Boolean` and `Duration` (written as milliseconds). The logging calls
  take up to six fields; join more with `&`.
- `Enabled (Level)` lets you skip building costly fields.
- **Batched.** Each task appends whole lines to a 16 KiB buffer of its own (shared by several tasks when there
  are more tasks than processors). One task writes the buffers out, one system call per buffer:
  - every `LOG_FLUSH_MS` (default 50);
  - sooner when a buffer is half full;
  - at once after a warning or an error.

  A task's lines stay in order and whole, and logging costs a copy, not a system call.
- `LOG_OVERFLOW=drop` drops lines (and counts them, in the next line written and in
  `sparrow_log_lines_dropped_total`) rather than making a task wait for the output. The default is to wait.
- `LOG_BUFFER=off` writes each line at once. Use it when chasing crashes: lines still buffered are lost when
  the process is killed.
- `Flush` writes what is buffered; the end of the program and the end of `Servers.Run` both call it.
  `Configure_Output` sets the same things in code.
- **`Line_Builder`**, for lines logged on every request: fields are formatted straight into a buffer on the
  stack, with no `Fields` built. The server's access log uses it; it costs about half of `Log`.
- Values are escaped, so client input cannot forge a line or a field. In JSON, bytes that are not UTF-8 are
  escaped too, so the line stays valid JSON.
- `Set_Sink` sends lines elsewhere (a file, a test), one call per line, not batched. The sink must be safe
  to call from several tasks at once.

In an HTTP handler, `Sparrow.Http.Log` adds the request's id to every line.

## Metrics

```ada
Orders  : constant Metrics.Counter := Metrics.New_Counter ("shop_orders_total", "Orders placed.");
Charged : constant Metrics.Histogram := Metrics.New_Histogram ("shop_charge_seconds", "Payment calls.");
...
Metrics.Add (Orders);
Metrics.Observe (Charged, Elapsed);   --  a Duration
```

- Counters, gauges (`Set`, `Add`) and histograms (`Latency_Bounds` by default, or your own `Bucket_Bounds`).
- Labels: `Metrics.Label ("route", "/users/:id") & Metrics.Label ("status", "2xx")`. Values are escaped.
- **Updates** are atomic additions: safe from any task, never blocking, no allocation.
- **Declaring** a metric takes a lock. Do it at start-up, as a library-level constant. Declaring the same
  name and labels again gives back the same metric.
- `Write_Text` renders every metric in the Prometheus text format. `Sparrow.Http.Health.Metrics` serves it
  on `/metrics`.
- Values are whole numbers; a histogram's sum is kept to a millionth (a microsecond).
- Room for 256 names and 4096 series. `Invalid_Metric` is raised past that, and for malformed names.

MIT licensed.
