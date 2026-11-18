# Benchmarks

Throughput and latency of `tests/demo_server` against an equivalent AWS server, on one machine over loopback.

```sh
tests/bench/run.sh            # Sparrow and AWS
tests/bench/run.sh sparrow    # Sparrow only
tests/bench/run.sh log        # only the access log's cost, writing to a file and to a pipe
SECONDS_PER_RUN=5 SERVER_CPUS=0-3 LOAD_CPUS=4-7 tests/bench/run.sh
```

| File | What it is |
|---|---|
| `load.c` | A multi-threaded epoll load generator, in the spirit of wrk. `load PORT PATH THREADS CONNECTIONS SECONDS DEPTH`: keep-alive connections, each with DEPTH requests in flight (1 = no pipelining). Prints requests/s, errors and, without pipelining, latency percentiles. Built by `run.sh` with gcc. |
| `aws_hello/` | An Alire crate: AWS 25.2 answering `hello` on port 18477. `MAX` sets `Max_Connection`. |
| `run.sh` | Builds both servers and the generator, pins the servers and the generator to separate CPUs, and runs every scenario. |

## Scenarios

- **64 connections, no pipelining:**
  - Sparrow's `/hello`, a route run on the reactor.
  - Sparrow's `/who/:name`, run by a worker.
  - AWS.
- **64 connections, 16 requests pipelined:** Sparrow and AWS.
- **1000 connections, no pipelining:** Sparrow, and AWS with `Max_Connection` 1000.
- **The access log's cost:** Sparrow with the log off and on, standard error written to a temporary file.

## Notes

- AWS 25.2 does not build with GNAT 16. `run.sh` selects GNAT 13.2.1 for the `aws_hello` crate only
  (`alr toolchain --select --local`), so Alire downloads that toolchain on the first run. Sparrow builds
  with the default toolchain. The two servers are therefore built by different compilers.
- AWS runs with its defaults except `Max_Connection`.
- The generator counts a connection the server closes as an error and does not reconnect. A run with
  errors has measured fewer clients than it started with.
- `tests/stress.py` is a correctness test under load (it checks every answer). It is single-threaded and
  cannot load the server enough to measure throughput.

## Results

Measured on 2026-11-17: 16 CPUs, servers on 0–7, load on 8–15, Sparrow with 8 reactors and 16 workers, 10 s
per run.

| Scenario | Sparrow, reactor route | Sparrow, worker route | AWS |
|---|---|---|---|
| 64 connections, no pipelining | 704k req/s, p50 0.09 ms, p99 0.20 ms | 271k req/s, p99 0.59 ms | 55k req/s, p50 1.16 ms, p99 1.43 ms |
| 64 connections, pipelining 16 | 850k req/s | — | 54k req/s |
| 1000 connections, no pipelining | 675k–684k req/s, p99 2.3–2.9 ms | 269k req/s, p99 6.1 ms | 66k–141k req/s (varies widely between runs), p99 14–23 ms, max 7–9 s |
| Access log off → on (64 connections), one write per line | 706k → 540k req/s (−24%) | | |
| Access log off → on, batched (2026-11-18), to a file | 696k–704k → 620k–630k req/s (−10%) | | |
| Access log off → on, batched (2026-11-18), to a pipe | 689k–700k → 632k–635k req/s (−9%) | | |

Memory and size:

| | Sparrow | AWS |
|---|---|---|
| Binary | 2.4 MB | 11.6 MB |
| Resident memory, idle | 110 MB; 12.5 MB since connection records are allocated on first use | 41 MB |
| Resident memory, 1000 connections | 113 MB, 25 threads; now 15.7 MB | 48 MB, 1002 threads |
