--  The libcrypto calls the Sparrow.Crypto bodies share.
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with System; use System;

private package Sparrow.Crypto.Libcrypto with SPARK_Mode => Off is

   --  Where Data starts; a valid pointer even for an empty string, which C code may not be given as null.
   function Start_Of (Data : String) return Address;

   --  Raise Crypto_Error naming What and libcrypto's reason, and clear its error queue.
   procedure Fail (What : String) with No_Return;

   --  Forget the reasons an expected refusal (a bad tag, a bad signature) left queued, so that they are not
   --  reported later as the cause of an unrelated failure on this thread (Sparrow.Tls reads the same queue).
   procedure Clear_Errors;

   --  The EVP_MD of an algorithm, and its name as EVP_KDF parameters spell it.
   function Digest_Of (Algorithm : Digest_Algorithm) return Address;
   function Name_Of (Algorithm : Digest_Algorithm) return String;   --  NUL-terminated

   --  OSSL_PARAM
   type Parameter is record
      Key         : Address := Null_Address;   --  a NUL-terminated name; null ends the list
      Data_Type   : unsigned := 0;
      Data        : Address := Null_Address;
      Data_Size   : size_t := 0;
      Return_Size : size_t := size_t'Last;     --  OSSL_PARAM_UNMODIFIED
   end record with Convention => C;
   type Parameter_List is array (Positive range <>) of Parameter with Convention => C;

   OSSL_PARAM_UNSIGNED_INTEGER : constant := 2;
   OSSL_PARAM_UTF8_STRING      : constant := 4;
   OSSL_PARAM_OCTET_STRING     : constant := 5;

   --  Whether the loaded providers have the EVP_KDF Name (NUL-terminated). Leaves the error queue empty.
   function Has_Kdf (Name : String) return Boolean;

   --  Length bytes from the EVP_KDF Name (NUL-terminated) with Parameters (ending with a null key).
   function Derive (Name : String; Parameters : Parameter_List; Length : Positive) return String
      with Post => Derive'Result'First = 1 and then Derive'Result'Length = Length;

   function EVP_MD_CTX_new return Address with Import, Convention => C, External_Name => "EVP_MD_CTX_new";
   procedure EVP_MD_CTX_free (Context : Address)
      with Import, Convention => C, External_Name => "EVP_MD_CTX_free";

end Sparrow.Crypto.Libcrypto;
