# sparrow_client

Outbound HTTP/1.1 and HTTPS, written in Ada, with TLS from the system's OpenSSL. Use it to call other services
from a handler: OAuth token endpoints, payment providers, webhooks, APIs.

```toml
[[depends-on]]
sparrow_client = "~0.1.0-dev"
```

```ada
Answer : Client.Response;
...
Client.Post ("https://oauth2.example/token",
             Client.Form_Pair ("grant_type", "authorization_code") & "&" & Client.Form_Pair ("code", Code),
             Answer, Media_Type => Client.Form_Media_Type);
if Client.Status (Answer) = 200 then
   Parse_Token (Client.Content (Answer));
end if;

Client.Get ("https://api.example/v1/items", Answer,
            Headers => "Authorization: Bearer " & Token & ASCII.LF & "Accept: application/json");
```

- `Get`, `Post`, and `Send` for any method. Extra headers are given one per line; Host, Content-Length and
  Connection are the client's own.
- `Status`, `Content` and `Header` (any case) read the answer; `Version` is 10 or 11.
- **Blocking.** Call it from handlers on workers, never on a reactor. Calls from different tasks run in
  parallel, each on its own connection, closed when the answer is in.
- **Safe defaults:**
  - Certificates are checked against the system's trust store (`Trust_File` replaces it), and the host name
    against the certificate.
  - Only `http` and `https`, also for redirects.
  - Redirects are not followed unless `Follow_Redirects`; a redirect to another origin drops your headers.
  - A 30 s timeout for the whole exchange, 10 s to connect.
  - At most 16 MiB of answer.
  - Header lines and URLs with line breaks or control bytes are refused, not sent.
- **Not done:** HTTP/2, compression (the content comes as the server sends it; ask for none), proxies,
  keeping connections open between calls.
- **Errors.** `Request_Error` means there was no answer: the URL or a header line was malformed, the name did
  not resolve, the connection or TLS failed, the time ran out, or the answer was malformed, cut short or too
  large. Any status, including 404 and 500, is an answer.
- `Url_Encode` and `Form_Pair` build query strings and form bodies.
- With `sparrow_http`, `Sparrow.Http.Log.Trace_Headers (Request)` passes the request's trace on to the
  service you call.

MIT licensed.
