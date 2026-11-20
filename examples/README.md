# Sparrow examples

Eight programs in one crate. Build once, then run each from this folder (they find their templates and files by
paths relative to it). Each listens on http://localhost:8080/ unless `PORT` says otherwise; stop with Ctrl-C.

```sh
alr build
bin/static_site     # or rest_service, todo_app, blob_game, forum, file_drop, notes_api, token_issuer
```

Every request is logged on standard error with its request id (also sent back as `X-Request-Id`), method,
path, status, size, time and client. `LOG_FORMAT=json` for log collectors, `LOG_LEVEL=debug|info|warning|error`,
`ACCESS_LOG=off` to keep only what the program itself logs.

## `snippets/`: the code of the guides

`SNIPPETS.md` and `GETTING_STARTED.md` (at the top of the repository) are generated: every piece of code they
show is a file in `snippets/src`, compiled with warnings as errors before the guides are written. Edit the files
and the `*.template.md` pages there, then run `snippets/generate.sh`. `snippets/generate.sh --check` (run by CI)
fails when a snippet does not compile or a guide is out of date.

## HTTPS and HTTP/2

Every example serves HTTPS when `CERT_FILE` and `KEY_FILE` name a certificate and its key (PEM). Browsers then
choose HTTP/2 through ALPN; older clients still get HTTP/1.1 on the same port. `make_cert.sh` makes a
self-signed pair for `localhost` here (browsers warn about it once):

```sh
./make_cert.sh
CERT_FILE=cert.pem KEY_FILE=key.pem PORT=8443 bin/forum      # then https://localhost:8443/
curl -k -w '%{http_version}\n' -o /dev/null https://localhost:8443/          # 2
```

Without them the examples serve plain HTTP, where HTTP/2 needs prior knowledge (`curl --http2-prior-knowledge`;
browsers use HTTP/2 only over TLS). The files are not committed: `.gitignore` leaves them out.

## `static_site`: a folder on the web

[static_site/src](static_site/src): the whole server is one route.

```ada
Routers.Add (Routes, Get, "/*file", Static.Folder (Site_Root, Max_Age => 60));
```

Media types from extensions, `ETag` and `Last-Modified` with 304 answers, `index.html` for folders, and a
redirect from `/about` to `/about/`. Paths that leave the folder and hidden files are 404. `SITE_ROOT` serves
another folder.

## `rest_service`: a JSON API

[rest_service/src](rest_service/src): bookmarks in SQLite, one connection per worker
(`Sparrow.Sqlite.Per_Worker`, schema by `Migrations` steps), request bodies read with `Requests.Json_Body`
and checked against one `Json.Rule_List`, answers written with a `Json.Builders.Builder`, writes behind an
HS256 bearer token. It serves `/healthz`, `/readyz` (the worker's database answers) and `/metrics`, and sends
traces to an OpenTelemetry collector when `OTEL_EXPORTER_OTLP_ENDPOINT` is set. The token is printed at
start-up:

```sh
bin/rest_service                      # logs "a token for writes token=eyJ..."
TOKEN=eyJ...
curl -X POST localhost:8080/api/bookmarks -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -d '{"url": "https://ada-lang.io", "title": "Ada"}'
curl 'localhost:8080/api/bookmarks?q=ada'
curl -X PUT localhost:8080/api/bookmarks/1 -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -d '{"url": "https://ada-lang.io/docs", "title": "Ada docs"}'
curl -X DELETE localhost:8080/api/bookmarks/1 -H "Authorization: Bearer $TOKEN"
```

Bad input gets `{"error": "..."}` with 400, 401, 404, 415 or 422. `API_SECRET` (32 bytes or more) keeps tokens
valid across restarts; `DATABASE` names the file.

## `todo_app`: htmx and templates

[todo_app](todo_app): Mustache templates in [todo_app/templates](todo_app/templates), a stylesheet, an icon
and htmx 2.0.4 (0BSD, vendored) in [todo_app/public](todo_app/public). The page is rendered once; every change
answers with the list fragment plus the footer swapped out of band, so counts and filters stay right. No
JavaScript of its own. Changes require the header htmx sends (`X-Requested-With`), which a cross-site form
cannot add: that is the CSRF defense.

## `blob_game`: Gobble

[blob_game](blob_game): blobs that eat pellets and each other; a blob 25% heavier eats a smaller one by covering
it. Twelve bots of mixed sizes fill the arena, so it plays well alone: they flee what can eat them, hunt what
they can eat, graze otherwise, and come back after being eaten. Open more windows to play against yourself.

The server owns the game: one protected object holds the world, and a task steps it 30 times a second and
pushes each player its view over the player's WebSocket (`/api/play`, a `Websockets.Endpoint`). The socket's
handlers only touch the protected object, so they run on the reactors without a worker hop. The browser sends
where its pointer is about 20 times a second and draws what is pushed, easing between views. `HOST=:: bin/blob_game` (or `HOST=0.0.0.0` for IPv4 only) to play across a network.

## `forum`: accounts, sessions and live updates

[forum](forum): a bulletin board in the manner of phpBB 2. Forums sit in categories. Each forum lists its
topics with reply and view counts and the last post. Topics show their posts 15 to a page, each beside its
author's rank, joining date and post count. Posts take BBCode (`[b] [i] [u] [quote] [code] [url]`) and can
be quoted. There is a memberlist. Everything is plain HTML forms, with no framework on the client.

- The pages use phpBB 2's table layout, CSS class names and image names. Any phpBB 2 style folder can dress
  them: `FORUM_STYLE=path/to/subSilver bin/forum`. The pages link the style's stylesheet, named after the
  folder (`subSilver/subSilver.css`), and its `images/` (`images/lang_english/post.gif` and the rest). The
  default style is [forum/styles/classic](forum/styles/classic).

- Passwords are Argon2id hashes (`Sparrow.Crypto.Passwords`), checked on workers. A login with an unknown name
  takes as long as one with a wrong password.
- Who is logged in lives in a sealed session cookie (`Sparrow.Http.Sessions`). Every form carries the session's
  CSRF token, and every POST checks it. The token is renewed at login; logging out clears the session.
- Messages for the next page ("Welcome back") are kept in the session and shown once.
- Open pages hear of new threads and replies over Server-Sent Events (`/events`, `Event_Streams` and a
  `Streams.Group`), and offer to show them.

- Account events go to the log with the request's id: `user registered`, `logged in`, and `login failed` as a
  warning (many from one client is someone guessing). `LOG_FORMAT=json bin/forum` for log-collector output.
- Logging in and registering are rate limited (`Sparrow.Http.Limits`): five tries per client, then one every
  ten seconds; past that, 429.

`SESSION_SECRET` (32 bytes or more) keeps people logged in across restarts; without it a random one is drawn
and the server says so. To change it without logging everyone out, set the old one as
`SESSION_SECRET_PREVIOUS` for a while. `DATABASE` names the SQLite file (default `forum.db`). With
`VALKEY_URL` set (`valkey://:password@host:6379`), sessions live in Valkey instead of the cookie, and the
login limit counts there too, so several forum servers share both.

## `file_drop`: big uploads, to disk or to S3

[file_drop](file_drop): drag files onto a page; every open page sees the list change at once.

- Uploads go to a `Body_Mode => Streamed` route, and `Multipart.Save_Stream` writes each file to disk as it
  arrives, so a file of any size passes through a few kilobytes of memory. `UPLOADS` names the folder (default
  `file_drop/uploads`); what is there already is listed at start.
- With `S3_BUCKET` set, the server only signs: the browser asks for a presigned PUT URL (`S3.Presigned_Put`),
  sends the file straight to the bucket, then tells the server, which checks the bucket has it (`S3.Size`).
  Downloads are redirects to presigned GET URLs. The keys come from `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_REGION` and, for a store other than AWS, `AWS_ENDPOINT_URL`.
- The list's changes reach every page over Server-Sent Events. Upload progress is the browser's own
  (`XMLHttpRequest` upload events): it is measured where the bytes leave.
- Writes need an `X-Requested-With` header, which a cross-site form cannot send. Stored names are reduced to
  letters, digits, `.`, `-` and `_`, so a name like `../../etc/passwd` stays in the folder.
- Over HTTPS, uploads, downloads and the event stream share one HTTP/2 connection, so a page uploading
  several files at once is not held to a browser's six HTTP/1.1 connections.

```sh
bin/file_drop                                        # files on disk
../tests/s3_server.sh                                # or a local S3 store (versitygw, port 19000)
S3_BUCKET=sparrow AWS_ACCESS_KEY_ID=sparrow-test AWS_SECRET_ACCESS_KEY=sparrow-test-secret \
  AWS_REGION=us-east-1 AWS_ENDPOINT_URL=http://127.0.0.1:19000 bin/file_drop
```

The browser talks to the bucket itself, so the bucket must allow the page's origin (CORS):

```sh
cat > cors.xml <<'XML'
<CORSConfiguration><CORSRule>
  <AllowedOrigin>http://localhost:8080</AllowedOrigin><AllowedOrigin>https://localhost:8443</AllowedOrigin>
  <AllowedMethod>PUT</AllowedMethod><AllowedMethod>GET</AllowedMethod><AllowedHeader>*</AllowedHeader>
</CORSRule></CORSConfiguration>
XML
curl -X PUT --aws-sigv4 'aws:amz:us-east-1:s3' --user sparrow-test:sparrow-test-secret \
  -H "Content-MD5: $(openssl md5 -binary cors.xml | base64)" --data-binary @cors.xml \
  'http://127.0.0.1:19000/sparrow?cors'
```

On AWS, `aws s3api put-bucket-cors` does the same.

## `notes_api` and `token_issuer`: tokens from somewhere else

[notes_api](notes_api): a JSON API of each user's notes, for users who sign in at another service. It is how
an API sits behind an identity provider, without depending on one: `token_issuer` stands in for it.

- `token_issuer` signs tokens with an Ed25519 key (`Jwt.Key_Sets.Sign`, EdDSA) and publishes the public half
  at `/.well-known/jwks.json`. Anyone may have a token under any name; it replaces a login. Its key is drawn at
  start, so restarting it rotates the key.
- `notes_api` fetches that JWKS with `sparrow_client` at start, and again when a token names a key it has not
  seen (at most every ten seconds), so a rotated key is picked up without a restart. `Jwt.Key_Sets.Verify`
  checks each token; `iss`, `aud` (`notes`) and `sub` are checked too.
- Notes live in Postgres. `Postgres.Migrations` creates the table at start; every worker has its own connection
  with prepared statements, opened in the worker hooks, and every query is scoped by the token's user: one user
  asking for another's note gets 404.
- `/healthz`, `/readyz` (is this worker's database connection up) and `/metrics`.

```sh
../tests/postgres_server.sh                          # a local Postgres on port 15432, or your own
podman exec sparrow-postgres-test psql -U postgres -c 'CREATE DATABASE notes'
PORT=8081 bin/token_issuer &
DATABASE_URL='postgres://postgres:sparrow%20p%C3%A4ssword@localhost:15432/notes' bin/notes_api

TOKEN=$(curl -s -X POST localhost:8081/token -H 'Content-Type: application/json' -d '{"user": "ada"}' \
        | sed 's/.*"token":"\([^"]*\)".*/\1/')
curl -X POST localhost:8080/api/notes -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' -d '{"text": "buy milk"}'
curl localhost:8080/api/notes -H "Authorization: Bearer $TOKEN"
```

`ISSUER_URL` (default `http://localhost:8081`) must be the same for both programs: it is the issuer's name in
its tokens and where its keys are fetched from.
