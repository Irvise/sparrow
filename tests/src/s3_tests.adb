with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Checks; use Checks;
with Sparrow.Client;
with Sparrow.S3; use Sparrow.S3;
with Sparrow.S3.Signatures; use Sparrow.S3.Signatures;

--  Signature V4 against AWS's own examples, then against the MinIO that s3_server.sh starts (skipped when
--  nothing listens on localhost:19000).
procedure S3_Tests is
   use Sparrow;

   LF : constant Character := ASCII.LF;

   --  From AWS's Signature V4 documentation for S3 ("Examples of the complete Version 4 signing process").
   Example_Secret : constant String := "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
   Empty_Hash     : constant String := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

   procedure Signature_Tests is
      Headers   : constant String :=
        "Host: examplebucket.s3.amazonaws.com" & LF & "Range: bytes=0-9" & LF
        & "x-amz-content-sha256:" & Empty_Hash & LF & "x-amz-date:20130524T000000Z";
      Canonical : constant String := Canonical_Request ("GET", "/test.txt", "", Headers, Empty_Hash);
   begin
      Equal (Amz_Date (1_369_353_600), "20130524T000000Z", "the date of a signature");
      Equal (Payload_Hash (""), Empty_Hash, "the hash of no payload");
      Equal (Canonical,
             "GET" & LF & "/test.txt" & LF & LF & "host:examplebucket.s3.amazonaws.com" & LF & "range:bytes=0-9" & LF
             & "x-amz-content-sha256:" & Empty_Hash & LF & "x-amz-date:20130524T000000Z" & LF & LF
             & "host;range;x-amz-content-sha256;x-amz-date" & LF & Empty_Hash,
             "AWS's example: the canonical request");
      Equal (Signature (Example_Secret, "us-east-1", "s3", "20130524T000000Z", Canonical),
             "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", "AWS's example: GET object");
      Equal (Signature
               (Example_Secret, "us-east-1", "s3", "20130524T000000Z",
                Canonical_Request
                  ("GET", "/test.txt",
                   "X-Amz-SignedHeaders=host&X-Amz-Expires=86400&X-Amz-Date=20130524T000000Z"
                   & "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"
                   & "&X-Amz-Algorithm=AWS4-HMAC-SHA256",
                   "host:examplebucket.s3.amazonaws.com", "UNSIGNED-PAYLOAD")),
             "aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404",
             "AWS's example: a presigned URL (query in any order)");
      Equal (Uri_Encode ("a b/ü~*") & " " & Uri_Encode ("a b/c", Keep_Slash => True), "a%20b%2F%C3%BC~%2A a%20b/c",
             "URI encoding");
      begin
         Check (Exists (Bucket_At ("ftp://x", "us-east-1", "bucket", "a", "b"), "k"), "a bad endpoint is refused");
      exception
         when Constraint_Error =>
            Check (True, "a bad endpoint is refused");
      end;
   end Signature_Tests;

   Store : constant Bucket :=
     Bucket_At ("http://localhost:19000", "us-east-1", "sparrow", "sparrow-test", "sparrow-test-secret");

   --  Whether Action raises S3_Error with a message starting with Code.
   function Refused (Code : String; Action : access procedure) return Boolean is
   begin
      Action.all;
      return False;
   exception
      when Problem : S3_Error =>
         declare
            Message : constant String := Ada.Exceptions.Exception_Message (Problem);
         begin
            if Ada.Strings.Fixed.Index (Message, Code) /= Message'First then
               Ada.Text_IO.Put_Line ("   refused for another reason: " & Message);
               return False;
            end if;
            return True;
         end;
   end Refused;

   Odd_Key : constant String := "a folder/a file ü+&=?.txt";
begin
   Signature_Tests;

   begin
      Put (Store, "hello.txt", "hello", Media_Type => "text/plain");
   exception
      when Problem : Client.Request_Error =>
         Ada.Text_IO.Put_Line ("s3: skipped, no test server (run tests/s3_server.sh): "
                               & Ada.Exceptions.Exception_Message (Problem));
         Finish ("s3");
         return;
   end;
   Check (Get (Store, "hello.txt") = "hello" and then Exists (Store, "hello.txt"), "put, then get");
   Check (Size (Store, "hello.txt") = 5 and then Size (Store, "no-such-object") = -1, "size by HEAD");

   declare
      Large : String (1 .. 3_000_000);
   begin
      for Index in Large'Range loop
         Large (Index) := Character'Val (Index mod 256);
      end loop;
      Put (Store, Odd_Key, Large);
      Check (Get (Store, Odd_Key) = Large, "3 MB of every byte, under a key that needs encoding");
      Delete (Store, Odd_Key);
      Check (not Exists (Store, Odd_Key), "delete");
   end;
   Delete (Store, "never there");
   Check (True, "deleting what is not there");

   declare
      procedure Missing is
         Unused : constant String := Get (Store, "never there");
      begin
         null;
      end Missing;

      procedure Wrong_Secret is
      begin
         Put (Bucket_At ("http://localhost:19000", "us-east-1", "sparrow", "sparrow-test", "not the secret"),
              "x", "y");
      end Wrong_Secret;

      procedure Wrong_Bucket is
      begin
         Put (Bucket_At ("http://localhost:19000", "us-east-1", "no-such-bucket", "sparrow-test",
                         "sparrow-test-secret"), "x", "y");
      end Wrong_Bucket;
   begin
      Check (Refused ("NoSuchKey", Missing'Access), "a missing object: NoSuchKey");
      Check (Refused ("SignatureDoesNotMatch", Wrong_Secret'Access), "a wrong secret: SignatureDoesNotMatch");
      Check (Refused ("NoSuchBucket", Wrong_Bucket'Access), "a missing bucket: NoSuchBucket");
   end;

   --  Presigned URLs, used without the keys.
   declare
      Answer : Client.Response;
      Url    : constant String := Presigned_Get (Store, "hello.txt", Lifetime => 60);
      Upload : constant String := Presigned_Put (Store, "uploaded.json", Media_Type => "application/json");
   begin
      Client.Get (Url, Answer);
      Check (Client.Status (Answer) = 200 and then Client.Content (Answer) = "hello", "a presigned GET");
      Client.Get (Url (Url'First .. Url'Last - 1) & (if Url (Url'Last) = '0' then "1" else "0"), Answer);
      Check (Client.Status (Answer) = 403, "a presigned GET with its signature changed");
      Client.Send ("PUT", Upload, Answer, Content => "{""a"":1}", Media_Type => "application/json");
      Check (Client.Status (Answer) = 200 and then Get (Store, "uploaded.json") = "{""a"":1}", "a presigned PUT");
      Client.Send ("PUT", Upload, Answer, Content => "<a/>", Media_Type => "text/xml");
      Check (Client.Status (Answer) = 403, "a presigned PUT with another media type");
      Delete (Store, "uploaded.json");
   end;

   Delete (Store, "hello.txt");
   Finish ("s3");
end S3_Tests;
