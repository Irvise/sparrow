with Interfaces.C; use Interfaces.C;
with Sparrow.Crypto.Libcrypto; use Sparrow.Crypto.Libcrypto;
with System; use System;

package body Sparrow.Crypto.Hashes with SPARK_Mode => Off is

   function EVP_Digest
     (Data : Address; Count : size_t; Into : Address; Size : access unsigned; Kind : Address; Engine : Address)
      return int
      with Import, Convention => C, External_Name => "EVP_Digest";

   function Hash (Algorithm : Digest_Algorithm; Data : String) return String is
      Result : aliased String (1 .. Digest_Length (Algorithm));
      Size   : aliased unsigned := 0;
   begin
      if EVP_Digest (Start_Of (Data), Data'Length, Result'Address, Size'Access, Digest_Of (Algorithm), Null_Address)
         /= 1 or else Size /= Result'Length
      then
         Fail ("EVP_Digest");
      end if;
      return Result;
   end Hash;

end Sparrow.Crypto.Hashes;
