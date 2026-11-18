# sparrow_s3

Objects in Amazon S3 and in the stores that speak its protocol (Cloudflare R2, Backblaze B2, Garage, Ceph,
versitygw, MinIO): put, get, delete, and presigned URLs, so that browsers upload and download directly
without your server in the middle.

```toml
[[depends-on]]
sparrow_s3 = "~0.1.0-dev"
```

```ada
Uploads : constant S3.Bucket := S3.Bucket_From_Environment ("uploads");
...
S3.Put (Uploads, "avatars/" & User & ".png", Image, Media_Type => "image/png");
Image := S3.Get (Uploads, "avatars/" & User & ".png");
if S3.Exists (Uploads, Key) then ... end if;
Bytes := S3.Size (Uploads, Key);   --  -1 when there is no such object
S3.Delete (Uploads, Key);
```

`Bucket_From_Environment` reads AWS's own variables: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_SESSION_TOKEN` (temporary credentials), `AWS_REGION`, and `AWS_ENDPOINT_URL_S3` or `AWS_ENDPOINT_URL` for
a store other than AWS. `Bucket_At` takes the same values as arguments. On `amazonaws.com` the bucket goes in
the host name; elsewhere in the path, as other stores expect.

## Presigned URLs

```ada
--  A link that downloads for five minutes:
Response.Redirect (S3.Presigned_Get (Uploads, Key, Lifetime => 300));

--  A form or script that uploads straight to the store:
Url := S3.Presigned_Put (Uploads, "incoming/" & Id, Media_Type => "image/jpeg");
```

Whoever holds the URL can do that one thing, to that one key, until it expires (at most a week). A PUT URL
made with a `Media_Type` takes only an upload with exactly that `Content-Type`.

## Errors and limits

- `S3_Error` carries the store's code and message: `NoSuchKey: ...`, `AccessDenied: ...`,
  `SignatureDoesNotMatch: ...`. `Client.Request_Error` means there was no answer at all.
- Every call blocks until the store answers: use buckets from handlers that run on workers.
- Objects go and come whole, in memory (up to `Client.Settings.Max_Response`, 16 MiB by default; raise it in
  `Using`). For larger files, have the browser use a presigned URL.
- Listing, multipart uploads and bucket management are not here; do those with the store's own tools.

## Signing

`Sparrow.S3.Signatures` is AWS Signature Version 4, which works for any AWS API. It is checked against AWS's
published examples, and against a real store in the tests (`tests/s3_server.sh` starts versitygw in a
container).

MIT licensed.
