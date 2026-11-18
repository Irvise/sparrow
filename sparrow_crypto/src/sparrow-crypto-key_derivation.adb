with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.Crypto.Libcrypto; use Sparrow.Crypto.Libcrypto;
with System; use System;

package body Sparrow.Crypto.Key_Derivation with SPARK_Mode => Off is

   function PKCS5_PBKDF2_HMAC
     (Password : Address; Password_Length : int; Salt : Address; Salt_Length : int; Iterations : int;
      Kind : Address; Length : int; Into : Address) return int
      with Import, Convention => C, External_Name => "PKCS5_PBKDF2_HMAC";

   function EVP_PBE_scrypt
     (Password : Address; Password_Length : size_t; Salt : Address; Salt_Length : size_t;
      N, R, P, Max_Memory : Unsigned_64; Into : Address; Length : size_t) return int
      with Import, Convention => C, External_Name => "EVP_PBE_scrypt";

   --  OSSL_PARAM entries
   function Octets (Key : String; Value : String) return Parameter is
     ((Key => Key'Address, Data_Type => OSSL_PARAM_OCTET_STRING, Data => Start_Of (Value),
       Data_Size => Value'Length, others => <>));
   function Number (Key : String; Value : aliased Unsigned_32) return Parameter is
     ((Key => Key'Address, Data_Type => OSSL_PARAM_UNSIGNED_INTEGER, Data => Value'Address, Data_Size => 4,
       others => <>));
   function Text (Key : String; Value : String) return Parameter is
     ((Key => Key'Address, Data_Type => OSSL_PARAM_UTF8_STRING, Data => Value'Address,
       Data_Size => Value'Length - 1, others => <>));   --  without its NUL
   End_Of_List : constant Parameter := (others => <>);

   Digest_Key   : aliased constant String := "digest" & ASCII.NUL;
   Key_Key      : aliased constant String := "key" & ASCII.NUL;
   Salt_Key     : aliased constant String := "salt" & ASCII.NUL;
   Info_Key     : aliased constant String := "info" & ASCII.NUL;
   Pass_Key     : aliased constant String := "pass" & ASCII.NUL;
   Iter_Key     : aliased constant String := "iter" & ASCII.NUL;
   Memcost_Key  : aliased constant String := "memcost" & ASCII.NUL;
   Lanes_Key    : aliased constant String := "lanes" & ASCII.NUL;

   Has_Argon2 : constant Boolean := Has_Kdf ("ARGON2ID" & ASCII.NUL);

   function Argon2_Available return Boolean is (Has_Argon2);

   function Pbkdf2
     (Algorithm  : Digest_Algorithm;
      Password   : String;
      Salt       : String;
      Iterations : Positive;
      Length     : Positive) return String
   is
      Result : aliased String (1 .. Length);
   begin
      if PKCS5_PBKDF2_HMAC (Start_Of (Password), int (Password'Length), Start_Of (Salt), int (Salt'Length),
                            int (Iterations), Digest_Of (Algorithm), int (Length), Result'Address) /= 1
      then
         Fail ("PKCS5_PBKDF2_HMAC");
      end if;
      return Result;
   end Pbkdf2;

   function Hkdf
     (Algorithm : Digest_Algorithm;
      Secret    : String;
      Salt      : String;
      Info      : String;
      Length    : Positive) return String
   is
      Name : aliased constant String := Name_Of (Algorithm);
   begin
      return Derive ("HKDF" & ASCII.NUL,
                     [Text (Digest_Key, Name), Octets (Key_Key, Secret), Octets (Salt_Key, Salt),
                      Octets (Info_Key, Info), End_Of_List],
                     Length);
   end Hkdf;

   function Scrypt
     (Password    : String;
      Salt        : String;
      Length      : Positive;
      Cost        : Scrypt_Cost := 15;
      Block_Size  : Positive := 8;
      Parallelism : Positive := 1) return String
   is
      N      : constant Unsigned_64 := 2 ** Cost;
      R      : constant Unsigned_64 := Unsigned_64 (Block_Size);
      P      : constant Unsigned_64 := Unsigned_64 (Parallelism);
      Result : aliased String (1 .. Length);
   begin
      --  The memory bound is what this call needs (OpenSSL's formula) plus slack; its default is only 32 MiB.
      if EVP_PBE_scrypt (Start_Of (Password), Password'Length, Start_Of (Salt), Salt'Length, N, R, P,
                         128 * R * (N + 2 + P) + 2 ** 20, Result'Address, size_t (Length)) /= 1
      then
         Fail ("EVP_PBE_scrypt");
      end if;
      return Result;
   end Scrypt;

   function Argon2id
     (Password   : String;
      Salt       : String;
      Length     : Positive;
      Memory     : Argon2_Memory;
      Iterations : Argon2_Iterations;
      Lanes      : Argon2_Lanes := 1) return String
   is
      Memory_Value     : aliased constant Unsigned_32 := Unsigned_32 (Memory);
      Iterations_Value : aliased constant Unsigned_32 := Unsigned_32 (Iterations);
      Lanes_Value      : aliased constant Unsigned_32 := Unsigned_32 (Lanes);
   begin
      --  One thread computes all lanes: more needs OSSL_set_max_threads, and the server has its own workers.
      return Derive ("ARGON2ID" & ASCII.NUL,
                     [Octets (Pass_Key, Password), Octets (Salt_Key, Salt), Number (Iter_Key, Iterations_Value),
                      Number (Memcost_Key, Memory_Value), Number (Lanes_Key, Lanes_Value), End_Of_List],
                     Length);
   end Argon2id;

end Sparrow.Crypto.Key_Derivation;
