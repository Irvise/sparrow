--  JSON Web Tokens: the input as a token (for a shared secret and for a key set), as a JWKS, and as the subject
--  of a token we sign.
--
--  Properties: Verify, Key_Sets.Verify, Key_Id_Of and Parse_Jwks return without raising on any input; a token
--  signed for a subject verifies with the same key before it expires and yields that subject, and not after it
--  expires nor with another key.
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Encoding;
with Sparrow.Json;
with Sparrow.Crypto.Public_Keys;
with Sparrow.Jwt; use Sparrow.Jwt;
with Sparrow.Jwt.Key_Sets;
with Sparrow.Times;

procedure Fuzz_Jwt is

   Now : constant Sparrow.Times.Unix_Seconds := 1_800_000_000;
   use type Sparrow.Times.Unix_Seconds;

   --  Everything Test uses is its own, so libFuzzer's callback needs no trampoline.
   procedure Test (Input : String) is
      Signing : constant Key := To_Key ("a key for fuzzing, which is 32 bytes or longer");
      Other   : constant Key := To_Key ("another key for fuzzing, also 32 bytes or longer");
      Claims  : Sparrow.Json.Document (Node_Capacity => 64, Text_Capacity => 4096);
      Valid   : Boolean;
   begin
      Verify (Signing, Input, Now, Claims, Valid);

      declare
         use Sparrow.Jwt.Key_Sets;
         Signer : constant Sparrow.Crypto.Public_Keys.Private_Key :=
           Sparrow.Crypto.Public_Keys.Ed25519_Private ([1 .. 32 => 'f']);
         Keys   : Key_Set := Parse_Jwks (Input);
         Kid    : constant String := Key_Id_Of (Input);
         pragma Unreferenced (Kid);
      begin
         Add (Keys, "fuzz", Sparrow.Crypto.Public_Keys.Public_Of (Signer));
         Key_Sets.Verify (Keys, Input, Now, Claims, Valid);
         Check (not Valid or else Input'Length <= Max_Signed_Token_Length, "a long token is refused");
      end;

      if Input'Length <= 256 and then Sparrow.Encoding.Valid_Utf8 (Input)
        and then (for all Item of Input => Item /= ASCII.NUL)
      then
         declare
            Token : constant String := Sign_Subject (Signing, Sparrow.UTF8_String (Input), Now, Lifetime => 3600);
         begin
            Verify (Signing, Token, Now + 10, Claims, Valid);
            Check (Valid, "a signed token verifies");
            Check (String (Sparrow.Json.Value (Claims, Sparrow.Json.Member (Claims, Sparrow.Json.Root, "sub")))
                   = Input,
                   "the subject reads back");
            Verify (Signing, Token, Now + 3601, Claims, Valid);
            Check (not Valid, "an expired token is refused");
            Verify (Other, Token, Now + 10, Claims, Valid);
            Check (not Valid, "another key's token is refused");
         end;
      end if;
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Jwt;
