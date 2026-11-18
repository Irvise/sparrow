with Sparrow; use Sparrow;
with Sparrow.Base64;
with Sparrow.Buffers;
with Sparrow.Crypto.Public_Keys;
with Sparrow.Crypto.Random;
with Sparrow.Crypto.Signatures;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.IO.Process;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Builders; use Sparrow.Json.Builders;
with Sparrow.Jwt.Key_Sets;
with Sparrow.Logs;

package body Issuer_Routes is

   package Requests renames Sparrow.Http.Requests;
   package Responses renames Sparrow.Http.Responses;

   Issuer   : constant String := Sparrow.IO.Process.Environment ("ISSUER_URL", Default => "http://localhost:8081");
   Lifetime : constant := 3600;

   Seed : Sparrow.Crypto.Signatures.Private_Key;

   --  The public key, as a JWK's "x", and the key's name: the start of it, so a new key has a new name.
   function Public_X return String is
     (Sparrow.Base64.Encode (Sparrow.Crypto.Signatures.Public_Of (Seed), Sparrow.Base64.Url_Safe));
   function Key_Id return String is (Public_X (1 .. 12));

   procedure Key_Set (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
      Json : Builder (Response.Content'Access);
   begin
      Responses.Begin_Content (Response, OK, Application_Json);
      Responses.Set_Header (Response, "Cache-Control", "max-age=300");
      Json.Begin_Object;
      Json.Key ("keys");
      Json.Begin_Array;
      Json.Begin_Object;
      Json.Member ("kty", "OKP");
      Json.Member ("crv", "Ed25519");
      Json.Member ("x", UTF8_String (Public_X));
      Json.Member ("kid", UTF8_String (Key_Id));
      Json.Member ("alg", "EdDSA");
      Json.Member ("use", "sig");
      Json.End_Object;
      Json.End_Array;
      Json.End_Object;
   end Key_Set;

   Token_Rules : constant Rule_List := [Required ("user", Text_Shape, Shortest => 1, Longest => 64)];

   procedure Token (Request : Http_Request; Response : in out Http_Response) is
      Fields : constant Document := Requests.Json_Body (Request);
      Now    : constant Long_Long_Integer := Long_Long_Integer (Requests.Now (Request));
      Claims : aliased Sparrow.Buffers.Buffer;
      Json   : Builder (Response.Content'Access);
   begin
      if not Is_Valid (Fields) or else Problem (Fields, Token_Rules) /= "" then
         Responses.Send (Response, Bad_Request, "send {""user"": ""a name""}");
         return;
      end if;
      declare
         Writer : Builder (Claims'Access);
      begin
         Writer.Begin_Object;
         Writer.Member ("iss", UTF8_String (Issuer));
         Writer.Member ("aud", "notes");
         Writer.Member ("sub", Text (Fields, "user"));
         Writer.Member ("iat", Now);
         Writer.Member ("exp", Now + Lifetime);
         Writer.End_Object;
      end;
      Responses.Begin_Content (Response, OK, Application_Json);
      Json.Begin_Object;
      Json.Member ("token", UTF8_String (Sparrow.Jwt.Key_Sets.Sign
                                           (Sparrow.Crypto.Public_Keys.Ed25519_Private (Seed), Key_Id,
                                            UTF8_String (Sparrow.Buffers.Content (Claims)))));
      Json.Member ("expires_in", Long_Long_Integer'(Lifetime));
      Json.End_Object;
      Sparrow.Buffers.Free (Claims);
      Sparrow.Logs.Info ("token issued", Sparrow.Logs.Field ("user", String (Text (Fields, "user"))));
   end Token;

   procedure Start is begin
      Sparrow.Crypto.Random.Fill (Seed);
      Sparrow.Logs.Info ("signing key", Sparrow.Logs.Field ("kid", Key_Id), Sparrow.Logs.Field ("issuer", Issuer));
   end Start;

end Issuer_Routes;
