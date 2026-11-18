--  Cryptography for web applications, bound to the system's OpenSSL 3.0 or later. Nothing here is implemented
--  in Ada: every primitive is libcrypto's, and TLS (Sparrow.Tls) is libssl's.
--
--  Bytes in, bytes out: keys, digests, signatures and ciphertexts are String. Results are indexed from 1.
--
--  SPARK: the specs carry contracts SPARK callers can rely on; the bodies call C and are not proved. A call
--  that libcrypto refuses for reasons outside the caller's control (no memory, a provider not loaded) raises
--  Crypto_Error, as running out of memory raises Storage_Error.
package Sparrow.Crypto with SPARK_Mode is

   Crypto_Error : exception;

   --  The oldest OpenSSL this crate runs on (OPENSSL_VERSION_NUMBER of 3.0.0). Argon2id needs 3.2; before it,
   --  Passwords uses scrypt (see Key_Derivation.Argon2_Available).
   Minimum_Version : constant := 16#3000_0000#;

   --  Why OpenSSL Version (OpenSSL_version_num) named Name cannot be used, or "" when it can. When the library
   --  the program actually loads fails this, the elaboration of this package writes the reason to standard
   --  error and ends the program with exit status 1: an old OpenSSL is a setup problem, reported before any
   --  work starts rather than as a failure on the first password hash.
   function Version_Problem (Version : Long_Long_Integer; Name : String) return String is
     (if Version >= Minimum_Version then ""
      else "Sparrow needs OpenSSL 3.0 or later, and this program loaded "
           & Name (Name'First .. Name'First - 1 + Integer'Min (Name'Length, 256))   --  OpenSSL's own name for it
           & ". Install or update the system's OpenSSL package (libssl, openssl@3), then start it again.");

   --  Sha1 is broken for signatures and certificates: it is here only because protocols still name it
   --  (the WebSocket handshake). Use one of the others for anything that needs to resist an attacker.
   type Digest_Algorithm is (Sha256, Sha384, Sha512, Sha3_256, Blake2b_512, Sha1);

   function Digest_Length (Algorithm : Digest_Algorithm) return Positive is
     (case Algorithm is
         when Sha1                  => 20,
         when Sha256 | Sha3_256     => 32,
         when Sha384                => 48,
         when Sha512 | Blake2b_512  => 64);

   --  Equality that takes the same time wherever the first difference is (CRYPTO_memcmp). Lengths are not
   --  treated as secret.
   function Constant_Time_Equal (Left, Right : String) return Boolean
      with Post => Constant_Time_Equal'Result = (Left = Right);

   --  Lower-case hexadecimal, for logs, ETags and test vectors.
   function To_Hex (Data : String) return String
      with Pre  => Data'Length <= 2 ** 24,
           Post => To_Hex'Result'First = 1 and then To_Hex'Result'Length = 2 * Data'Length;

end Sparrow.Crypto;
