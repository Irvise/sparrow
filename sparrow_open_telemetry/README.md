# sparrow_open_telemetry

Sends the traces of a Sparrow server to an OpenTelemetry collector (OTLP over HTTP, JSON). The collector can pass
them on to Jaeger, Tempo, Honeycomb, Datadog or any other tracing backend.

```toml
[[depends-on]]
sparrow_open_telemetry = "~0.1.0-dev"
```

```ada
Open_Telemetry.Start (Service => "bookmarks", Endpoint => "http://localhost:4318/v1/traces");
Servers.Run (Settings, Routes);
Open_Telemetry.Stop;   --  sends what is left
```

Or read the standard variables, and start only when an endpoint is set:

```ada
Open_Telemetry.Start_From_Environment ("bookmarks", Started);
```

| Variable | Use |
|---|---|
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | The full URL to send to |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Otherwise: a base URL, to which `/v1/traces` is added |
| `OTEL_SERVICE_NAME` | `service.name` (else the default given) |
| `OTEL_TRACES_SAMPLER_ARG` | The share of new traces to keep, 0 to 1 (else 1) |
| `OTEL_EXPORTER_OTLP_HEADERS` | Extra headers, `name=value,name=value`, values percent-encoded |

## What is sent

- **One span per request**, made by the server: named after the route (`GET /users/:id`), with the method,
  route, path and status. A 5xx answer marks it as an error.
- **Spans that handlers start**, with `Sparrow.Http.Spans` (in sparrow_http): nested by scope, marked as errors
  with `Spans.Fail`.
- **Sampling.** A request whose caller sent a `traceparent` is traced if the caller's trace was. Otherwise
  `Sample_Ratio` of new traces are, chosen by trace id, so every service with the same ratio keeps the same
  traces whole.

## Costs and failures

- Finished spans wait in a bounded queue (`Queue_Limit`, 4096). One task sends them in batches (`Batch_Size`,
  512): once a second, or as soon as a batch is full.
- Requests never wait for the collector. When the queue is full, or a batch cannot be sent, spans are dropped
  and counted in `sparrow_open_telemetry_spans_dropped_total{reason="queue_full"|"send_failed"}`.
- The first failure is logged as a warning, and so is the recovery; the failures in between are not.
- `Flush` sends what is queued and waits until it has gone.

MIT licensed.
