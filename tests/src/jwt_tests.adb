with Checks; use Checks;
with Sparrow.Json; use Sparrow.Json;
with Jwt_Vectors;
with Sparrow.Base64;
with Sparrow.Crypto.Macs;
with Sparrow.Crypto.Public_Keys; use Sparrow.Crypto.Public_Keys;
with Sparrow.Crypto;
with Sparrow.Jwt; use Sparrow.Jwt;
with Sparrow.Jwt.Key_Sets; use Sparrow.Jwt.Key_Sets;
with Sparrow.Times; use Sparrow.Times;

procedure Jwt_Tests is
   Secret : constant Key := To_Key ("your-256-bit-secret");
   Claims : Document (Node_Capacity => 32, Text_Capacity => 1024);
   Valid  : Boolean;

   --  The example token of jwt.io (HS256, secret "your-256-bit-secret"), which has no exp.
   Known : constant String :=
     "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
     & "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ."
     & "SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
begin
   Verify (Secret, Known, 1_600_000_000, Claims, Valid, Require_Expiry => False);
   Check (Valid, "known token verifies");
   Equal (String (Value (Claims, Member (Claims, Root, "name"))), "John Doe", "known token claims");
   Verify (Secret, Known, 1_600_000_000, Claims, Valid);
   Check (not Valid, "a token without exp is refused by default");
   Verify (To_Key ("another secret"), Known, 1_600_000_000, Claims, Valid, Require_Expiry => False);
   Check (not Valid, "wrong key");

   declare
      Token    : constant String := Sign_Subject (Secret, "user ""42""", Now => 1000, Lifetime => 60);
      Tampered : String := Token;
   begin
      Verify (Secret, Token, 1030, Claims, Valid);
      Check (Valid, "round trip");
      Equal (String (Value (Claims, Member (Claims, Root, "sub"))), "user ""42""", "subject survives quoting");
      Verify (Secret, Token, 1060, Claims, Valid);
      Check (not Valid, "expired");
      Tampered (Tampered'First + 40) := (if Tampered (Tampered'First + 40) = 'A' then 'B' else 'A');
      Verify (Secret, Tampered, 1030, Claims, Valid);
      Check (not Valid, "tampered payload");
   end;

   declare
      --  {"alg":"none"} header with a valid-looking body
      None : constant String := Sign (Secret, "{""exp"":99999999999}");
      Forged : constant String := "eyJhbGciOiJub25lIn0" & None (37 .. None'Last);
   begin
      Verify (Secret, None, 1000, Claims, Valid);
      Check (Valid, "plain claims verify");
      Verify (Secret, Forged, 1000, Claims, Valid);
      Check (not Valid, "alg none is refused");
   end;

   Verify (Secret, Sign (Secret, "{""exp"":2000,""nbf"":1500}"), 1000, Claims, Valid);
   Check (not Valid, "not yet valid");
   Verify (Secret, "", 1000, Claims, Valid);
   Check (not Valid, "empty token");
   Verify (Secret, "a.b", 1000, Claims, Valid);
   Check (not Valid, "two segments");
   Verify (Secret, "a.b.c.d", 1000, Claims, Valid);
   Check (not Valid, "four segments");

   Equal (Bearer_Token ("Bearer abc.def"), "abc.def", "bearer");
   Equal (Bearer_Token ("token abc"), "abc", "token scheme");
   Equal (Bearer_Token ("Basic abc"), "", "other scheme");
   Equal (Bearer_Token ("Bearer"), "", "no token");

   Key_Set_Tests :
   declare
      use Jwt_Vectors;
      Keys : constant Key_Set := Parse_Jwks (Jwks);
      Late : constant Unix_Seconds := 4_102_444_800;   --  the vectors' exp

      function Verifies (Token : String; Using : Key_Set := Keys; Now : Unix_Seconds := 1_700_000_000)
         return Boolean
      is
         Result : Boolean;
      begin
         Key_Sets.Verify (Using, Token, Now, Claims, Result);
         return Result;
      end Verifies;

      function Url (Text : String) return String is (Sparrow.Base64.Encode (Text, Sparrow.Base64.Url_Safe));

      --  Token with its header replaced by Header (and the signature kept).
      function With_Header (Token : String; Header : String) return String is
         Dot : Natural := 0;
      begin
         for Index in Token'Range loop
            if Token (Index) = '.' then
               Dot := Index;
               exit;
            end if;
         end loop;
         return Url (Header) & Token (Dot .. Token'Last);
      end With_Header;

      --  Token with one character of its payload changed.
      function Tampered (Token : String) return String is
         Result : String := Token;
         Dot    : Natural := 0;
      begin
         for Index in Result'Range loop
            if Result (Index) = '.' then
               Dot := Index;
               exit;
            end if;
         end loop;
         Result (Dot + 2) := (if Result (Dot + 2) = 'A' then 'B' else 'A');
         return Result;
      end Tampered;
   begin
      Check (Count (Keys) = 3 and then Has_Key (Keys, "rsa1") and then Has_Key (Keys, "ec1")
             and then Has_Key (Keys, "ed1") and then not Has_Key (Keys, "enc1") and then not Has_Key (Keys, "small")
             and then not Has_Key (Keys, "secret"),
             "a JWKS: signing keys kept; encryption, weak RSA and shared secrets left out");
      Check (Verifies (Rs256_Token), "RS256 from another implementation verifies");
      Equal (String (Value (Claims, Member (Claims, Root, "sub"))), "42", "RS256 claims");
      Check (Verifies (Es256_Token), "ES256 from another implementation verifies");
      Check (Verifies (Eddsa_Token), "EdDSA from another implementation verifies");
      Check (not Verifies (Small_Rsa_Token), "a 1024-bit RSA key is not trusted");
      Check (not Verifies (Wrong_Kid_Token), "a signature by another key than the one named");
      Check (not Verifies (Tampered (Rs256_Token)) and then not Verifies (Tampered (Es256_Token))
             and then not Verifies (Tampered (Eddsa_Token)), "a changed payload");
      Check (not Verifies (Rs256_Token, Now => Late), "expired");
      Check (not Verifies (Rs256_Token, Using => Empty_Set), "no keys");
      Check (not Verifies (With_Header (Rs256_Token, "{""alg"":""ES256"",""kid"":""rsa1""}"))
             and then not Verifies (With_Header (Rs256_Token, "{""alg"":""none"",""kid"":""rsa1""}"))
             and then not Verifies (With_Header (Rs256_Token, "{""alg"":""RS256""}")),
             "a header that changes the algorithm or drops the key");
      declare
         --  The classic confusion: HS256 with the RSA public key as the secret.
         Forged_Head : constant String := Url ("{""alg"":""HS256"",""kid"":""rsa1""}");
         Forged_Body : constant String := Url ("{""sub"":""admin"",""exp"":4102444800}");
         Forged_Mac  : constant String :=
           Sparrow.Crypto.Macs.Hmac (Sparrow.Crypto.Sha256, Rsa_Public_Pem, Forged_Head & "." & Forged_Body);
      begin
         Check (not Verifies (Forged_Head & "." & Forged_Body & "." & Url (Forged_Mac)),
                "HS256 signed with the RSA public key is refused");
      end;
      Equal (Key_Id_Of (Es256_Token), "ec1", "the kid of a header");
      Equal (Key_Id_Of ("not a token") & Key_Id_Of ("a.b.c") & Key_Id_Of (""), "", "the kid of garbage");

      --  Signing, then verifying with the public half.
      declare
         procedure Round_Trip (Pem : String) is
            Signer : constant Private_Key := Private_From_Pem (Pem);
            Token  : constant String := Key_Sets.Sign (Signer, "mine", "{""sub"":""7"",""exp"":4102444800}");
            Mine   : Key_Set;
         begin
            Add (Mine, "mine", Public_Of (Signer));
            Check (Is_Valid (Signer) and then Verifies (Token, Using => Mine)
                   and then String (Value (Claims, Member (Claims, Root, "sub"))) = "7"
                   and then not Verifies (Token),
                   "sign and verify with " & Algorithm_Of (Sparrow.Crypto.Public_Keys.Kind (Signer)));
         end Round_Trip;
      begin
         Round_Trip (Rsa_Private_Pem);
         Round_Trip (Ec_Private_Pem);
         Round_Trip (Ed25519_Private_Pem);
      end;
      declare
         Public : constant Public_Key := From_Pem (Rsa_Public_Pem);
         Mine   : Key_Set;
      begin
         Add (Mine, "rsa1", Public);
         Check (Sparrow.Crypto.Public_Keys.Kind (Public) = Rsa and then Verifies (Rs256_Token, Using => Mine),
                "a public key from PEM");
      end;
      declare
         Seed   : constant String (1 .. 32) := [others => 's'];
         Signer : constant Private_Key := Ed25519_Private (Seed);
         Alone  : Key_Set;
      begin
         Add (Alone, "", Public_Of (Signer));
         Check (Verifies (Key_Sets.Sign (Signer, "", "{""exp"":4102444800}"), Using => Alone),
                "a set of one key takes tokens that name none");
      end;
      Check (not Is_Valid (Ec_P256_Key ([1 .. 32 => 'x'], [1 .. 32 => 'y'])), "a point not on the curve");
      Check (not Is_Valid (Ed25519_Key ("short")) and then not Is_Valid (From_Pem ("not PEM"))
             and then not Is_Valid (Private_From_Pem ("")) and then not Is_Valid (Rsa_Key ("", "")),
             "malformed keys are invalid, not exceptions");
   end Key_Set_Tests;

   Finish ("jwt");
end Jwt_Tests;
