--  The routes of file_drop. Files live in a folder (Body_Mode => Streamed uploads, written to disk as they
--  arrive) or, with S3_BUCKET set, in an S3 bucket the browser uploads to directly with presigned URLs.
--
--     GET    /api/files               {"mode": "local" | "s3", "files": [{"name": ..., "size": ...}]}
--     POST   /api/files               local: a multipart/form-data upload of "file" parts      201 + the list
--     POST   /api/uploads             s3: {"name", "type", "size"} -> {"name", "url"}, a PUT URL for 15 minutes
--     POST   /api/uploads/:name/done  s3: the browser's PUT is done; the server checks the bucket has it
--     DELETE /api/files/:name         204
--     GET    /api/events              an event stream: "changed" whenever the list does
--     GET    /files/:name             the file (local), or a redirect to a presigned GET URL (s3)
--
--  Writes require the X-Requested-With header, which a cross-site form cannot send: the CSRF defense.
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Drop_Api is

   --  Local: Folder holds the files (and Folder/.incoming the uploads in progress); what is there already is
   --  listed. S3: Bucket names the bucket, its keys and endpoint come from AWS_* as Sparrow.S3 reads them.
   procedure Use_Folder (Folder : String);
   procedure Use_Bucket (Bucket : String);

   function Uses_Bucket return Boolean;

   procedure List (Request : Http_Request; Response : in out Http_Response);
   procedure Upload (Request : Http_Request; Response : in out Http_Response);
   procedure Presign (Request : Http_Request; Response : in out Http_Response);
   procedure Uploaded (Request : Http_Request; Response : in out Http_Response);
   procedure Remove (Request : Http_Request; Response : in out Http_Response);
   procedure Events (Request : Http_Request; Response : in out Http_Response);
   procedure Download (Request : Http_Request; Response : in out Http_Response);   --  s3

end Drop_Api;
