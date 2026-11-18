--  File drop: drag files onto a page and they are stored; every open page sees the list change at once.
--
--     cd examples && bin/file_drop          then open http://localhost:8080/
--
--  Without S3_BUCKET, uploads stream to disk as they arrive (a Body_Mode => Streamed route and
--  Multipart.Save_Stream), so a file of any size passes through a few kilobytes of memory. UPLOADS names the
--  folder (default file_drop/uploads).
--
--  With S3_BUCKET (and AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION, AWS_ENDPOINT_URL for a store other
--  than AWS), the server only signs: the browser PUTs each file straight to the bucket with a presigned URL, and
--  downloads are redirects to presigned GET URLs. The bucket must allow the page's origin (CORS); see README.
--
--  An event stream tells open pages when the list changes. With CERT_FILE and KEY_FILE the page is served over
--  HTTPS, and browsers then use HTTP/2: uploads, downloads and the event stream share one connection.
with Drop_Api;
with Example_Tls;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Http.Static;
with Sparrow.IO.Process;

procedure File_Drop is
   Bucket : constant String := Sparrow.IO.Process.Environment ("S3_BUCKET");
   Folder : constant String := Sparrow.IO.Process.Environment ("UPLOADS", Default => "file_drop/uploads");
   Routes : Router (Capacity => 12);
begin
   if Bucket /= "" then
      Drop_Api.Use_Bucket (Bucket);
   else
      Drop_Api.Use_Folder (Folder);
   end if;

   Add (Routes, Get, "/api/files", Drop_Api.List'Access, On_Reactor);
   Add (Routes, Post, "/api/files", Drop_Api.Upload'Access, Body_Mode => Streamed);
   Add (Routes, Post, "/api/uploads", Drop_Api.Presign'Access);
   Add (Routes, Post, "/api/uploads/:name/done", Drop_Api.Uploaded'Access);
   Add (Routes, Delete, "/api/files/:name", Drop_Api.Remove'Access);
   Add (Routes, Get, "/api/events", Drop_Api.Events'Access, On_Reactor);
   if Drop_Api.Uses_Bucket then
      Add (Routes, Get, "/files/*file", Drop_Api.Download'Access, On_Reactor);   --  signing is local work
   else
      Add (Routes, Get, "/files/*file", Static.Folder (Folder));
   end if;
   Add (Routes, Get, "/*file", Static.Folder ("file_drop/public", Max_Age => 60));

   Sparrow.Http.Servers.Run (Sparrow.Http.Servers.From_Environment, Routes, Security => Example_Tls.Security);
end File_Drop;
