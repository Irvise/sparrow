--  Sparrow.Crypto against published vectors (FIPS 180, RFC 4231, 5869, 7914, 8439, 8032) and, for Argon2id, the
--  reference implementation's command-line tool.
with Ada.Text_IO; use Ada.Text_IO;
with Checks; use Checks;
with Sparrow.Crypto; use Sparrow.Crypto;
with Sparrow.Crypto.Ciphers; use Sparrow.Crypto.Ciphers;
with Sparrow.Crypto.Hashes; use Sparrow.Crypto.Hashes;
with Sparrow.Crypto.Key_Derivation; use Sparrow.Crypto.Key_Derivation;
with Sparrow.Crypto.Macs; use Sparrow.Crypto.Macs;
with Sparrow.Crypto.Passwords;
with Sparrow.Crypto.Random;
with Sparrow.Crypto.Signatures; use Sparrow.Crypto.Signatures;

procedure Crypto_Tests is

   --  The bytes hexadecimal Text spells.
   function Bytes (Text : String) return String is
      function Value (Symbol : Character) return Natural is
        (if Symbol in '0' .. '9' then Character'Pos (Symbol) - Character'Pos ('0')
         else Character'Pos (Symbol) - Character'Pos ('a') + 10);
      Result : String (1 .. Text'Length / 2);
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val (16 * Value (Text (Text'First + 2 * Index - 2))
                                          + Value (Text (Text'First + 2 * Index - 1)));
      end loop;
      return Result;
   end Bytes;

   --  The bytes with codes First .. Last.
   function Run (First, Last : Natural) return String is
     ([for Index in 1 .. Last - First + 1 => Character'Val (First + Index - 1)]);

begin
   --  digests of "abc"
   Equal (To_Hex (Hash (Sha256, "abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256");
   Equal (To_Hex (Hash (Sha256, "")), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "sha256 empty");
   Equal (To_Hex (Hash (Sha384, "abc")),
          "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "sha384");
   Equal (To_Hex (Hash (Sha512, "abc")),
          "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
          & "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "sha512");
   Equal (To_Hex (Hash (Sha1, "abc")), "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1 (legacy, for WebSockets)");
   Equal (To_Hex (Hash (Sha3_256, "abc")), "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532",
          "sha3-256");
   Equal (To_Hex (Hash (Blake2b_512, "abc")),
          "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
          & "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923", "blake2b-512");

   --  RFC 4231 cases 1, 2 and 6 (a key longer than the block)
   Equal (To_Hex (Hmac (Sha256, [1 .. 20 => Character'Val (16#0B#)], "Hi There")),
          "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "hmac-sha256 1");
   Equal (To_Hex (Hmac (Sha256, "Jefe", "what do ya want for nothing?")),
          "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "hmac-sha256 2");
   Equal (To_Hex (Hmac (Sha512, "Jefe", "what do ya want for nothing?")),
          "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea250554"
          & "9758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737", "hmac-sha512 2");
   Equal (To_Hex (Hmac (Sha256, [1 .. 131 => Character'Val (16#AA#)],
                        "Test Using Larger Than Block-Size Key - Hash Key First")),
          "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "hmac-sha256 6");
   declare
      Long_Secret : constant String := [1 .. 300 => 'k'];
   begin
      Check (Hmac (To_Hmac_Key (Sha384, Long_Secret), "data") = Hmac (Sha384, Long_Secret, "data")
             and then Hmac (To_Hmac_Key (Sha256, "Jefe"), "what do ya want for nothing?")
                      = Hmac (Sha256, "Jefe", "what do ya want for nothing?"),
             "prepared hmac keys agree");
   end;

   Check (Constant_Time_Equal ("abc", "abc") and then not Constant_Time_Equal ("abc", "abd")
          and then not Constant_Time_Equal ("abc", "ab") and then Constant_Time_Equal ("", ""),
          "constant time equal");

   --  RFC 7914 section 11 (PBKDF2-HMAC-SHA256), RFC 5869 case 1, RFC 7914 section 12 (scrypt)
   Equal (To_Hex (Pbkdf2 (Sha256, "passwd", "salt", 1, 32)),
          "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc", "pbkdf2 1 iteration");
   Equal (To_Hex (Pbkdf2 (Sha256, "Password", "NaCl", 80_000, 32)),
          "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56", "pbkdf2 80000 iterations");
   Equal (To_Hex (Hkdf (Sha256, [1 .. 22 => Character'Val (16#0B#)], Run (0, 12), Run (16#F0#, 16#F9#), 42)),
          "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "hkdf");
   Equal (To_Hex (Scrypt ("password", "NaCl", 64, Cost => 10, Block_Size => 8, Parallelism => 16)),
          "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162"
          & "2eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640", "scrypt");

   --  stored passwords: scrypt everywhere, Argon2id where OpenSSL has it (3.2 or later)
   declare
      use Sparrow.Crypto.Passwords;
      Cheap        : constant Cost := (Memory => 1024, Iterations => 2, Lanes => 1);
      Cheap_Scrypt : constant Fallback_Cost := (Log_N => 10, Block_Size => 8, Parallelism => 1);
      Reference    : constant String :=   --  argon2 saltsaltsaltsalt -id -t 2 -k 1024 -p 1 -e
        "$argon2id$v=19$m=1024,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$MO33cCFnqSA8SskhR8/i5r/vajJ3mDxwI/Myoh5GZwk";
      Scrypt_Reference : constant String :=   --  Python's hashlib.scrypt, n=2**10, r=8, p=1, 32 bytes
        "$scrypt$ln=10,r=8,p=1$c2FsdHNhbHRzYWx0c2FsdA$A9lBa6RTbfBovWqamVIqXKovIl4Vk6OZyVojLJmYmSI";
      Salt         : Salt_Bytes;
   begin
      Check (Preferred = (if Argon2_Available then Argon2id else Scrypt), "preferred algorithm");
      Equal (Hash ("correct horse", "saltsaltsaltsalt", Fallback => Cheap_Scrypt, Kind => Scrypt), Scrypt_Reference,
             "scrypt hash format");
      Check (Verify ("correct horse", Scrypt_Reference), "scrypt password verifies");
      Check (not Verify ("correct horsf", Scrypt_Reference), "scrypt: wrong password");
      Check (not Verify ("x", "$scrypt$ln=24,r=64,p=1$c2FsdHNhbHRzYWx0c2FsdA$A9lBa6RTbfBovWqamVIqXKovIl4Vk6OZ"),
             "scrypt hash asking too much memory refused");
      Check (not Verify ("x", "$scrypt$ln=10,r=8,p=1$"), "malformed scrypt hash");
      Check (not Needs_Rehash (Scrypt_Reference, Fallback => Cheap_Scrypt) = (Preferred = Scrypt),
             "an scrypt hash needs rehashing exactly when Argon2id is there");
      Check (not Verify ("x", "not a hash"), "malformed hash");
      Sparrow.Crypto.Random.Fill (Salt);
      Check (Verify ("pässword", Hash ("pässword", Salt, Cheap, Cheap_Scrypt)), "password round trip");

      if Argon2_Available then
         --  Argon2id, against the reference implementation (argon2 somesalt -id -t 2 -k 65536 -p 1)
         Equal (To_Hex (Argon2id ("password", "somesalt", 32, Memory => 65_536, Iterations => 2)),
                "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7", "argon2id");
         Equal (Hash ("correct horse", "saltsaltsaltsalt", Cheap), Reference, "password hash format");
         Check (Verify ("correct horse", Reference), "password verifies");
         Check (not Verify ("correct horsf", Reference), "wrong password");
         Check (not Verify ("correct horse", Reference (1 .. Reference'Last - 1) & "x"), "changed hash");
         Check (not Verify ("x", "$argon2id$v=19$m=1024,t=2,p=1$"), "malformed argon2id hash");
         Check (not Verify ("x", "$argon2id$v=19$m=999999999,t=2,p=1$c2FsdHNhbHRzYWx0c2FsdA$MO33cCFnqSA8Sskh"),
                "hash asking too much memory refused");
         Check (not Needs_Rehash (Reference, Cheap) and then Needs_Rehash (Reference), "needs rehash");
      else
         Put_Line ("crypto: OpenSSL has no Argon2id (before 3.2): checking the scrypt fallback instead");
         begin
            Check (not Verify ("correct horse", Reference), "an Argon2id hash without Argon2id is refused");
            Check (False, "an Argon2id hash without Argon2id raises");
         exception
            when Crypto_Error => Check (True, "an Argon2id hash without Argon2id raises");
         end;
         Check (Needs_Rehash (Reference, Cheap), "an Argon2id hash needs rehashing without Argon2id");
      end if;
   end;

   --  RFC 8439 2.8.2: ChaCha20-Poly1305
   declare
      Key    : constant Key_Bytes := Run (16#80#, 16#9F#);
      Nonce  : constant Nonce_Bytes := Bytes ("070000004041424344454647");
      Data   : constant String := Bytes ("50515253c0c1c2c3c4c5c6c7");
      Plain  : constant String := "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for "
                                  & "the future, sunscreen would be it.";
      Sealed : constant String := Seal (Chacha20_Poly1305, Key, Nonce, Plain, Data);
      Opened : String (1 .. Plain'Length);
      Last   : Natural;
      Valid  : Boolean;
   begin
      Equal (To_Hex (Sealed (1 .. 16)), "d31a8d34648e60db7b86afbc53ef7ec2", "chacha20-poly1305 text");
      Equal (To_Hex (Sealed (Sealed'Last - 15 .. Sealed'Last)), "1ae10b594f09e26a7e902ecbd0600691",
             "chacha20-poly1305 tag");
      Open (Chacha20_Poly1305, Key, Nonce, Sealed, Opened, Last, Valid, Data);
      Check (Valid and then Opened (1 .. Last) = Plain, "chacha20-poly1305 opens");
      Open (Chacha20_Poly1305, Key, Nonce, Sealed, Opened, Last, Valid, "other");
      Check (not Valid and then Last = 0, "wrong associated data refused");
   end;

   --  AES-256-GCM round trip and tampering
   declare
      Key    : Key_Bytes;
      Nonce  : Nonce_Bytes;
      Opened : String (1 .. 5);
      Last   : Natural;
      Valid  : Boolean;
   begin
      Sparrow.Crypto.Random.Fill (Key);
      Sparrow.Crypto.Random.Fill (Nonce);
      declare
         Sealed  : constant String := Seal (Aes_256_Gcm, Key, Nonce, "hello");
         Changed : String := Sealed;
      begin
         Check (Sealed'Length = 5 + Tag_Length, "aes-gcm length");
         Open (Aes_256_Gcm, Key, Nonce, Sealed, Opened, Last, Valid);
         Check (Valid and then Opened (1 .. Last) = "hello", "aes-gcm opens");
         Changed (1) := Character'Val ((Character'Pos (Changed (1)) + 1) mod 256);
         Open (Aes_256_Gcm, Key, Nonce, Changed, Opened, Last, Valid);
         Check (not Valid and then Opened = [1 .. 5 => ASCII.NUL], "aes-gcm tampering refused");
         Open (Aes_256_Gcm, Key, Nonce, Sealed (1 .. 10), Opened, Last, Valid);
         Check (not Valid, "aes-gcm short text refused");
      end;
      declare
         Empty_Sealed : constant String := Seal (Aes_256_Gcm, Key, Nonce, "");
      begin
         Open (Aes_256_Gcm, Key, Nonce, Empty_Sealed, Opened, Last, Valid);
         Check (Empty_Sealed'Length = Tag_Length and then Valid and then Last = 0, "aes-gcm empty");
      end;
   end;

   --  RFC 8032 7.1 test 1: Ed25519
   declare
      Secret : constant Private_Key := Bytes ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
      Public : constant Public_Key := Public_Of (Secret);
      Signed : constant Signature := Sign (Secret, "");
   begin
      Equal (To_Hex (Public), "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "ed25519 public");
      Equal (To_Hex (Signed), "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc"
                              & "61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", "ed25519 signature");
      Check (Verify (Public, "", Signed), "ed25519 verifies");
      Check (not Verify (Public, "x", Signed) and then not Verify (Public, "", Signed (1 .. 63)),
             "ed25519 refuses");
   end;

   --  the start-up check on the OpenSSL version
   Check (Version_Problem (16#3060_0050#, "OpenSSL 3.6.5") = "" and then Version_Problem (16#3000_000D#, "x") = ""
          and then Version_Problem (16#4010_0000#, "OpenSSL 4.1.0") = "", "openssl 3.0 and later accepted");
   Check (Version_Problem (16#1010_117F#, "OpenSSL 1.1.1w 11 Sep 2023")'Length > 0
          and then Version_Problem (16#2000_0000#, "LibreSSL 3.3.6")'Length > 0, "older openssl refused");

   --  random
   declare
      One, Two : String (1 .. 32);
      Token    : String (1 .. 64);
      Last     : Natural;
   begin
      Sparrow.Crypto.Random.Fill (One);
      Sparrow.Crypto.Random.Fill (Two);
      Check (One /= Two, "random differs");
      Sparrow.Crypto.Random.Token (24, Token, Last);
      Check (Last = 32 and then (for all Symbol of Token (1 .. Last) =>
                                    Symbol in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_'), "random token");
   end;

   Finish ("crypto");
end Crypto_Tests;
