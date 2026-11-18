--  HS256 JSON Web Tokens (RFC 7519). The claims are whatever JSON object the application chooses; this unit
--  signs them, and on the way back checks the signature and the time claims before anything else is read.
--
--  SPARK: no token, however malformed, makes Verify raise or read outside it.
with Sparrow.Crypto.Macs;
with Sparrow.Json;
with Sparrow.Times; use Sparrow.Times;

package Sparrow.Jwt with SPARK_Mode is

   Max_Token_Length : constant := 4096;

   --  A signing key, prepared once (at start-up) from the secret.
   type Key is private;
   function To_Key (Secret : String) return Key;

   --  A token carrying Claims, the text of a JSON object (build it with Sparrow.Json.Writers). Claims is signed
   --  as given: put iat and exp in it.
   function Sign (Using : Key; Claims : UTF8_String) return String
      with Pre  => Claims'Length <= 2048,
           Post => Sign'Result'First = 1 and then Sign'Result'Length <= Max_Token_Length;

   --  The usual token: {"sub": Subject, "iat": Now, "exp": Now + Lifetime}. Subject holds no NUL character,
   --  which Verify (like every JSON this stack reads) refuses.
   function Sign_Subject
     (Using : Key; Subject : UTF8_String; Now : Unix_Seconds; Lifetime : Unix_Seconds) return String
      with Pre  => Subject'Length <= 256 and then (for all Item of Subject => Item /= ASCII.NUL)
                   and then Now in 0 .. 10 ** 15 and then Lifetime in 1 .. 10 ** 15,
           Post => Sign_Subject'Result'First = 1 and then Sign_Subject'Result'Length <= Max_Token_Length;

   --  Valid when the signature matches, alg is HS256, exp (required unless Require_Expiry is False) is after
   --  Now and nbf, if any, is not after Now. Claims then holds the payload: read sub and the rest from it.
   procedure Verify
     (Using          : Key;
      Token          : String;
      Now            : Unix_Seconds;
      Claims         : in out Json.Document;
      Valid          : out Boolean;
      Require_Expiry : Boolean := True)
      with Pre => Token'First >= 1 and then Token'Last < Positive'Last and then Claims.Text_Capacity < Positive'Last;

   --  The token of an "Authorization: Bearer <token>" (or "Token <token>") header value; "" for anything else.
   function Bearer_Token (Authorization : String) return String
      with Post => Bearer_Token'Result'Length <= Authorization'Length;

private

   --  For the units that check other signatures (Key_Sets): the rest of Verify, once a token's signature has
   --  been checked. Valid when the header's alg is Algorithm and the times hold (as Verify says); Claims then
   --  holds the payload. First_Dot and Second_Dot are the token's two dots.
   procedure Check_Signed
     (Token          : String;
      First_Dot      : Positive;
      Second_Dot     : Positive;
      Algorithm      : String;
      Now            : Unix_Seconds;
      Claims         : in out Json.Document;
      Valid          : out Boolean;
      Require_Expiry : Boolean)
      with Pre => Token'First >= 1 and then Token'Last < Positive'Last and then Token'Length <= 65_536
                  and then First_Dot in Token'Range
                  and then Second_Dot in First_Dot + 1 .. Token'Last
                  and then Claims.Text_Capacity < Positive'Last;

   type Key is record
      Mac : Crypto.Macs.Hmac_Key;
   end record;

end Sparrow.Jwt;
