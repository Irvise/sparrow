--  Stored passwords in the PHC string format, so a stored hash carries its own algorithm and parameters, and
--  old ones keep verifying after the defaults change:
--
--     $argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>     where OpenSSL has Argon2id (3.2 or later)
--     $scrypt$ln=15,r=8,p=3$<salt>$<hash>              on OpenSSL 3.0 and 3.1
--
--  Hash writes Argon2id when it can. Verify reads both. Needs_Rehash says yes to an scrypt hash once Argon2id
--  is there, so moving to a newer OpenSSL upgrades each user's hash at their next login. The reverse does not
--  work: an Argon2id hash cannot be checked without Argon2id, and Verify raises Crypto_Error rather than
--  answer False and lock the user out unnoticed.
--
--  Hashing takes tens of milliseconds and tens of MiB: never call this on a reactor. Route it to a worker.
with Sparrow.Crypto.Key_Derivation; use Sparrow.Crypto.Key_Derivation;

package Sparrow.Crypto.Passwords with SPARK_Mode is

   type Algorithm is (Argon2id, Scrypt);

   --  Argon2id where Argon2_Available, else scrypt.
   function Preferred return Algorithm is (if Argon2_Available then Argon2id else Scrypt);

   type Cost is record
      Memory     : Argon2_Memory     := 19_456;   --  KiB; OWASP's minimum for Argon2id
      Iterations : Argon2_Iterations := 2;
      Lanes      : Argon2_Lanes      := 1;
   end record
      with Dynamic_Predicate => Cost.Memory >= 8 * Cost.Lanes;

   Default_Cost : constant Cost := (others => <>);

   --  scrypt's parameters, used where Argon2id is missing: N = 2 ** Log_N. The default is one of OWASP's
   --  settings (N = 2 ** 15, r = 8, p = 3): 32 MiB, comparable to Argon2id's default.
   subtype Scrypt_Block_Size is Positive range 1 .. 64;
   subtype Scrypt_Parallelism is Positive range 1 .. 16;
   type Fallback_Cost is record
      Log_N       : Scrypt_Cost        := 15;
      Block_Size  : Scrypt_Block_Size  := 8;
      Parallelism : Scrypt_Parallelism := 3;
   end record;

   Default_Fallback : constant Fallback_Cost := (others => <>);

   --  The memory a scrypt hash with these parameters takes, in KiB (128 * r * N bytes).
   function Memory_Of (Using : Fallback_Cost) return Long_Long_Integer is
     (Long_Long_Integer (Using.Block_Size) * 2 ** Using.Log_N / 8);

   --  Verify refuses stored hashes that ask for more than this, so a planted hash cannot exhaust memory.
   Max_Memory : constant Argon2_Memory := 1_048_576;   --  KiB: 1 GiB

   Max_Password_Length : constant := 4096;
   Max_Hash_Length     : constant := 128;
   subtype Salt_Bytes is String (1 .. 16);

   --  A fresh stored hash of Password, with Kind's cost. Draw Salt with Sparrow.Crypto.Random.Fill. Kind is
   --  there for tests and migrations; leave it to default.
   function Hash
     (Password : String;
      Salt     : Salt_Bytes;
      Using    : Cost          := Default_Cost;
      Fallback : Fallback_Cost := Default_Fallback;
      Kind     : Algorithm     := Preferred) return String
      with Pre  => Password'Length <= Max_Password_Length
                   and then Using.Memory <= Max_Memory
                   and then Memory_Of (Fallback) <= Long_Long_Integer (Max_Memory),
           Post => Hash'Result'First = 1 and then Hash'Result'Length <= Max_Hash_Length;

   --  Whether Password matches Stored, compared in constant time. False for a malformed hash or one whose
   --  parameters exceed Max_Memory. Raises Crypto_Error for an Argon2id hash where Argon2id is missing.
   function Verify (Password : String; Stored : String) return Boolean;

   --  Whether Stored was made with another algorithm than Preferred, or another cost than Using (Argon2id)
   --  or Fallback (scrypt), or is malformed: rehash at the next login.
   function Needs_Rehash
     (Stored   : String;
      Using    : Cost          := Default_Cost;
      Fallback : Fallback_Cost := Default_Fallback) return Boolean;

end Sparrow.Crypto.Passwords;
