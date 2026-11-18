--  Objects in Amazon S3 and the stores that speak its protocol (MinIO, Cloudflare R2, Backblaze B2, Garage,
--  Ceph): put, get, delete, and presigned URLs that let a browser upload or download directly.
--
--     Uploads : constant S3.Bucket := S3.Bucket_From_Environment ("uploads");
--     ...
--     S3.Put (Uploads, "avatars/" & User & ".png", Image, Media_Type => "image/png");
--     Response.Redirect (S3.Presigned_Get (Uploads, "avatars/" & User & ".png", Lifetime => 300));
--
--  Requests are signed with AWS Signature Version 4 (Sparrow.S3.Signatures) and made with sparrow_client, so
--  every call blocks: run handlers that use a bucket on workers.
with Sparrow.Client;
private with Ada.Strings.Unbounded;

package Sparrow.S3 is

   --  The store refused a request: the message is its error code and message ("NoSuchKey: The specified key
   --  does not exist."). Client.Request_Error when there was no answer at all.
   S3_Error : exception;

   type Bucket is private;

   --  Endpoint: the store's base URL ("https://s3.eu-west-1.amazonaws.com", "http://localhost:9000"). On
   --  amazonaws.com the bucket goes in the host name (virtual-hosted style); elsewhere in the path, as other
   --  stores expect. Session_Token: for temporary credentials, "" otherwise.
   function Bucket_At
     (Endpoint      : String;
      Region        : String;
      Name          : String;
      Access_Key    : String;
      Secret_Key    : String;
      Session_Token : String := "";
      Using         : Client.Settings := Client.Default_Settings) return Bucket
      with Pre => Name'Length in 3 .. 63 and then Region'Length > 0;

   --  The same from AWS's variables: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN, AWS_REGION
   --  (else us-east-1), and AWS_ENDPOINT_URL_S3 or AWS_ENDPOINT_URL (else AWS in that region).
   --  Constraint_Error when the keys are missing.
   function Bucket_From_Environment (Name : String) return Bucket
      with Pre => Name'Length in 3 .. 63;

   --  Store Content under Key, replacing what was there.
   procedure Put
     (Where      : Bucket;
      Key        : String;
      Content    : String;
      Media_Type : String := "application/octet-stream")
      with Pre => Key'Length in 1 .. 1024;

   --  The object under Key: S3_Error ("NoSuchKey: ...") when there is none.
   function Get (Where : Bucket; Key : String) return String
      with Pre => Key'Length in 1 .. 1024;

   function Exists (Where : Bucket; Key : String) return Boolean
      with Pre => Key'Length in 1 .. 1024;

   --  The size in bytes of the object under Key, or -1 when there is none (one HEAD request, as Exists).
   function Size (Where : Bucket; Key : String) return Long_Long_Integer
      with Pre => Key'Length in 1 .. 1024;

   --  Delete Key; deleting what is not there is not an error.
   procedure Delete (Where : Bucket; Key : String)
      with Pre => Key'Length in 1 .. 1024;

   --  A URL that lets whoever holds it GET Key, or PUT it, for Lifetime seconds (at most a week), without the
   --  keys. For a PUT URL, the uploader must send exactly Media_Type as Content-Type.
   function Presigned_Get (Where : Bucket; Key : String; Lifetime : Positive := 900) return String
      with Pre => Key'Length in 1 .. 1024 and then Lifetime <= 604_800;
   function Presigned_Put
     (Where : Bucket; Key : String; Media_Type : String := ""; Lifetime : Positive := 900) return String
      with Pre => Key'Length in 1 .. 1024 and then Lifetime <= 604_800;

private

   use Ada.Strings.Unbounded;

   type Bucket is record
      Scheme        : Unbounded_String;   --  "https://"
      Host          : Unbounded_String;   --  with the port when it is not the scheme's, and the bucket when virtual
      Base_Path     : Unbounded_String;   --  "/bucket" in path style, "" otherwise
      Region        : Unbounded_String;
      Access_Key    : Unbounded_String;
      Secret_Key    : Unbounded_String;
      Session_Token : Unbounded_String;
      Using         : Client.Settings;
   end record;

end Sparrow.S3;
