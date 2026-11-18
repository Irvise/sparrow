--  Keys from passwords and from other keys. For stored passwords use Sparrow.Crypto.Passwords, which wraps
--  Argon2id in a self-describing string.
package Sparrow.Crypto.Key_Derivation with SPARK_Mode is

   Max_Length : constant := 1024;

   --  PBKDF2 (RFC 8018) with HMAC over Algorithm. SCRAM-SHA-256 uses it with Sha256 and 32 bytes.
   function Pbkdf2
     (Algorithm  : Digest_Algorithm;
      Password   : String;
      Salt       : String;
      Iterations : Positive;
      Length     : Positive) return String
      with Pre  => Length <= Max_Length and then Password'Length <= 2 ** 30 and then Salt'Length <= 2 ** 30,
           Post => Pbkdf2'Result'First = 1 and then Pbkdf2'Result'Length = Length;

   --  HKDF (RFC 5869), extract then expand: keys for separate purposes from one secret.
   function Hkdf
     (Algorithm : Digest_Algorithm;
      Secret    : String;
      Salt      : String;
      Info      : String;
      Length    : Positive) return String
      with Pre  => Length <= Max_Length,
           Post => Hkdf'Result'First = 1 and then Hkdf'Result'Length = Length;

   --  scrypt (RFC 7914) with N = 2 ** Cost. Memory is about 128 * Block_Size * 2 ** Cost bytes.
   subtype Scrypt_Cost is Positive range 1 .. 24;
   function Scrypt
     (Password    : String;
      Salt        : String;
      Length      : Positive;
      Cost        : Scrypt_Cost := 15;
      Block_Size  : Positive := 8;
      Parallelism : Positive := 1) return String
      with Pre  => Length <= Max_Length and then Block_Size <= 64 and then Parallelism <= 16,
           Post => Scrypt'Result'First = 1 and then Scrypt'Result'Length = Length;

   --  Whether OpenSSL has Argon2id: 3.2 and later do. Fixed for the life of the program.
   function Argon2_Available return Boolean;

   --  Argon2id (RFC 9106). Memory in KiB; it takes that much memory and Iterations passes over it. Raises
   --  Crypto_Error where it is not Argon2_Available.
   subtype Argon2_Memory is Positive range 8 .. 4_194_304;   --  up to 4 GiB
   subtype Argon2_Iterations is Positive range 1 .. 1000;
   subtype Argon2_Lanes is Positive range 1 .. 64;
   function Argon2id
     (Password   : String;
      Salt       : String;
      Length     : Positive;
      Memory     : Argon2_Memory;
      Iterations : Argon2_Iterations;
      Lanes      : Argon2_Lanes := 1) return String
      with Pre  => Length in 4 .. Max_Length and then Salt'Length >= 8 and then Memory >= 8 * Lanes,
           Post => Argon2id'Result'First = 1 and then Argon2id'Result'Length = Length;

end Sparrow.Crypto.Key_Derivation;
