# Getting started

From nothing to a running web server in Ada: install the tools, make a crate, add Sparrow, write a handler.

## 1. Install Alire

[Alire](https://alire.ada.dev) is Ada's package manager. It fetches the compiler (GNAT), the build tool
(gprbuild) and libraries such as Sparrow.

1. Download `alr` for your system from [alire.ada.dev](https://alire.ada.dev) or the
   [releases page](https://github.com/alire-project/alire/releases), and put it on your `PATH`.
2. Choose a compiler. Sparrow needs GNAT 13 or later; take the newest `gnat_native` offered:

   ```sh
   alr toolchain --select
   ```

3. Check: `alr version` prints the version and your platform.

## 2. Install the system libraries

Sparrow binds a few C libraries the operating system keeps up to date. Install the ones for the crates you use;
a web server (`sparrow_http`) needs only OpenSSL.

| Crate | Library |
|---|---|
| `sparrow_http`, `sparrow_crypto`, `sparrow_jwt`, `sparrow_valkey`, `sparrow_client`, `sparrow_s3`, `sparrow_open_telemetry` | OpenSSL 3.0 or later |
| `sparrow_postgres` | libpq 16 or later |
| `sparrow_sqlite` | SQLite 3 |

| System | Command (all three) |
|---|---|
| Debian, Ubuntu | `sudo apt install libssl-dev libpq-dev libsqlite3-dev` |
| Fedora | `sudo dnf install openssl-devel libpq-devel sqlite-devel` |
| Arch | `sudo pacman -S openssl postgresql-libs sqlite` |
| macOS (Homebrew) | `brew install openssl@3 libpq sqlite` |
| Windows | Alire installs MSYS2 on first use and offers to install the libraries through it |

Alire may report these as missing on systems whose package names it does not know (macOS, Arch). If they are
installed, the build still works.

## 3. Make a crate

```sh
alr init --bin hello
cd hello
```

This makes `alire.toml` (the manifest), `hello.gpr` (the project file) and `src/hello.adb`.

## 4. Add Sparrow

Sparrow uses Ada 2022, which a new crate does not turn on. Add this to `alire.toml`:

```toml
[build-switches]
"*".ada_version = "ada2022"
```

Then add the web server crate:

```sh
alr with sparrow_http
```

> **Before 0.1.0 is published,** the crates are not in Alire's index yet. Clone the repository next to your
> crate (`git clone https://github.com/michael-hardeman/sparrow`) and add this to `alire.toml` instead of
> `alr with`. Alire does not follow a pinned crate's own pins, so each Sparrow crate it needs is pinned here:
>
> ```toml
> [[depends-on]]
> sparrow_http = "~0.1.0-dev"
>
> [[pins]]
> sparrow_http   = { path = "../sparrow/sparrow_http" }
> sparrow_core   = { path = "../sparrow/sparrow_core" }
> sparrow_io     = { path = "../sparrow/sparrow_io" }
> sparrow_crypto = { path = "../sparrow/sparrow_crypto" }
> sparrow_json   = { path = "../sparrow/sparrow_json" }
> ```
>
> Run `alr update` after editing the manifest by hand.

## 5. Write the server

A handler is a procedure that reads the request and fills in the response. It lives in a package, not inside
the main procedure, so that the router can keep a pointer to it.

Create `src/hello_pages.ads` and `src/hello_pages.adb`:

@include src/hello_pages.ads src/hello_pages.adb

Replace `src/hello.adb`:

@include src/hello.adb

- `Router (Capacity => 8)` holds up to 8 routes. `:name` captures a path segment, read back with
  `Parameter_Text`.
- `Sparrow.UTF8_String` is text, and `String` is bytes. `use Sparrow` makes `&` work on text.
- `Servers.Run` serves until Ctrl-C (or SIGTERM), then lets requests in flight finish.

## 6. Build and run

```sh
alr build
bin/hello
```

```
2026-11-18T16:45:30.131Z INFO    server started address=127.0.0.1 port=8080 reactors=16 workers=8 ...
```

In another terminal:

```sh
$ curl localhost:8080/hello/ada
Hello, ada!
```

Each request gets one log line, with an id that is also sent back as `X-Request-Id`:

```
2026-11-18T16:45:31.134Z INFO    request request_id=277ac2f4… method=GET path=/hello/ada status=200 bytes=11 ms=0.071 client=127.0.0.1
```

`PORT=3000 bin/hello` listens elsewhere; `HOST=0.0.0.0` accepts other machines. gzip compression is on
already, and HTTP/2 too once the server has a certificate (see the HTTPS snippet).

## 7. Next

- [SNIPPETS.md](SNIPPETS.md): copyable pieces for JSON, HTTPS, sessions, databases, templates, WebSockets,
  uploads and the rest, each compiled as it is shown.
- [`examples/`](examples): eight complete programs, from a static site to a multiplayer game.
- Each crate's README (`sparrow_http/README.md` and so on) for the whole of what it does.

Ready for production: build with `alr build --release`, serve HTTPS (see the snippet), and put the secrets
(`SESSION_SECRET` and the like) in the environment rather than in the source.
