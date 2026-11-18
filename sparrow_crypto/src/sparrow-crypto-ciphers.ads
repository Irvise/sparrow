--  Authenticated encryption: AES-256-GCM and ChaCha20-Poly1305, each with a 32-byte key, a 12-byte nonce and a
--  16-byte tag.
--
--  A nonce must never repeat under one key. Draw it with Sparrow.Crypto.Random.Fill and store it beside the
--  sealed text; with random nonces, rotate a key before it has sealed about 2 ** 32 messages.
package Sparrow.Crypto.Ciphers with SPARK_Mode is

   type Aead_Algorithm is (Aes_256_Gcm, Chacha20_Poly1305);

   subtype Key_Bytes is String (1 .. 32);
   subtype Nonce_Bytes is String (1 .. 12);
   Tag_Length : constant := 16;
   Max_Length : constant := 2 ** 30;

   --  Plain encrypted, followed by the tag, which also covers Associated (sent or known in the clear).
   function Seal
     (Algorithm  : Aead_Algorithm;
      Key        : Key_Bytes;
      Nonce      : Nonce_Bytes;
      Plain      : String;
      Associated : String := "") return String
      with Pre  => Plain'Length <= Max_Length and then Associated'Length <= Max_Length,
           Post => Seal'Result'First = 1 and then Seal'Result'Length = Plain'Length + Tag_Length;

   --  The plain text of Sealed into Plain (First .. Last), or Valid = False when the tag does not match: the
   --  wrong key, nonce or associated data, or a changed text. Plain is cleared then.
   procedure Open
     (Algorithm  : Aead_Algorithm;
      Key        : Key_Bytes;
      Nonce      : Nonce_Bytes;
      Sealed     : String;
      Plain      : out String;
      Last       : out Natural;
      Valid      : out Boolean;
      Associated : String := "")
      with Pre  => Sealed'Length <= Max_Length + Tag_Length and then Associated'Length <= Max_Length
                   and then Plain'First = 1 and then Plain'Length >= Sealed'Length - Tag_Length,
           Post => (if Valid then Last = Sealed'Length - Tag_Length else Last = 0);

end Sparrow.Crypto.Ciphers;
