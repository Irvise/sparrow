with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests; use Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.IO.Process;
with Sparrow.Json;
with Sparrow.Jwt;

package body Api_Tokens is

   --  JWT_SECRET: 32 random bytes or more.
   Signing : constant Jwt.Key :=
     Jwt.To_Key (Sparrow.IO.Process.Environment ("JWT_SECRET"));

   --  POST /token. In real life, after checking a password.
   procedure Issue
     (Request : Http_Request; Response : in out Http_Response)
   is
      Token : constant String :=
        Jwt.Sign_Subject
          (Signing, Subject => "user-42", Now => Now (Request),
           Lifetime => 3600);
   begin
      Responses.Send (Response, OK, UTF8_String (Token));   --  JWTs are ASCII
   end Issue;

   --  GET /private with "Authorization: Bearer <token>"
   procedure Private_Page
     (Request : Http_Request; Response : in out Http_Response)
   is
      Token  : constant String :=
        Jwt.Bearer_Token (Header (Request, "Authorization"));
      Claims : Json.Document (Node_Capacity => 64, Text_Capacity => 4096);
      Valid  : Boolean;
   begin
      Jwt.Verify (Signing, Token, Now (Request), Claims, Valid);
      if not Valid then
         Responses.Set_Header (Response, "WWW-Authenticate", "Bearer");
         Responses.Fail (Response, Unauthorized);
         return;
      end if;
      Responses.Send (Response, OK, "Hello, " & Json.Text (Claims, "sub"));
   end Private_Page;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Post, "/token", Issue'Access);
      Add (Routes, Get, "/private", Private_Page'Access);
   end Register;

end Api_Tokens;
