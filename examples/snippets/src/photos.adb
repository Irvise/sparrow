with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests; use Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.S3;

package body Photos is

   --  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_REGION; also
   --  AWS_ENDPOINT_URL for a store other than AWS.
   Bucket : constant Sparrow.S3.Bucket :=
     Sparrow.S3.Bucket_From_Environment ("photos");

   function Key_Of (Request : Http_Request) return String is
     ("photos/" & Parameter (Request, "name"));

   --  PUT /photos/:name with the image as the body
   procedure Store
     (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.S3.Put (Bucket, Key_Of (Request), Content (Request),
                      Media_Type => "image/jpeg");
      Responses.Send (Response, Created, "stored");
   end Store;

   --  GET /photos/:name: the browser downloads from the store directly,
   --  with a link good for five minutes.
   procedure Fetch
     (Request : Http_Request; Response : in out Http_Response) is
   begin
      Responses.Redirect
        (Response,
         Sparrow.S3.Presigned_Get (Bucket, Key_Of (Request), Lifetime => 300));
   end Fetch;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Put, "/photos/:name", Store'Access);
      Add (Routes, Get, "/photos/:name", Fetch'Access);
   end Register;

end Photos;
