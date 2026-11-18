with Interfaces.C; use Interfaces.C;
with Sparrow.Crypto.Libcrypto; use Sparrow.Crypto.Libcrypto;
with System; use System;

package body Sparrow.Crypto.Signatures with SPARK_Mode => Off is

   EVP_PKEY_ED25519 : constant := 1087;

   function EVP_PKEY_new_raw_private_key (Kind : int; Engine : Address; Key : Address; Length : size_t)
      return Address
      with Import, Convention => C, External_Name => "EVP_PKEY_new_raw_private_key";
   function EVP_PKEY_new_raw_public_key (Kind : int; Engine : Address; Key : Address; Length : size_t)
      return Address
      with Import, Convention => C, External_Name => "EVP_PKEY_new_raw_public_key";
   function EVP_PKEY_get_raw_public_key (Key : Address; Into : Address; Length : access size_t) return int
      with Import, Convention => C, External_Name => "EVP_PKEY_get_raw_public_key";
   procedure EVP_PKEY_free (Key : Address) with Import, Convention => C, External_Name => "EVP_PKEY_free";
   function EVP_DigestSignInit
     (Context : Address; Key_Context : Address; Kind : Address; Engine : Address; Key : Address) return int
      with Import, Convention => C, External_Name => "EVP_DigestSignInit";
   function EVP_DigestSign
     (Context : Address; Into : Address; Length : access size_t; Data : Address; Count : size_t) return int
      with Import, Convention => C, External_Name => "EVP_DigestSign";
   function EVP_DigestVerifyInit
     (Context : Address; Key_Context : Address; Kind : Address; Engine : Address; Key : Address) return int
      with Import, Convention => C, External_Name => "EVP_DigestVerifyInit";
   function EVP_DigestVerify
     (Context : Address; Signed : Address; Signed_Length : size_t; Data : Address; Count : size_t) return int
      with Import, Convention => C, External_Name => "EVP_DigestVerify";

   function Private_Of (Key : Private_Key) return Address is
      Result : constant Address := EVP_PKEY_new_raw_private_key (EVP_PKEY_ED25519, Null_Address, Key'Address, 32);
   begin
      if Result = Null_Address then
         Fail ("EVP_PKEY_new_raw_private_key");
      end if;
      return Result;
   end Private_Of;

   function Public_Of (Key : Private_Key) return Public_Key is
      Pair   : constant Address := Private_Of (Key);
      Result : aliased Public_Key;
      Length : aliased size_t := Result'Length;
      Status : constant int := EVP_PKEY_get_raw_public_key (Pair, Result'Address, Length'Access);
   begin
      EVP_PKEY_free (Pair);
      if Status /= 1 or else Length /= Result'Length then
         Fail ("EVP_PKEY_get_raw_public_key");
      end if;
      return Result;
   end Public_Of;

   function Sign (Key : Private_Key; Message : String) return Signature is
      Pair    : constant Address := Private_Of (Key);
      Context : constant Address := EVP_MD_CTX_new;
      Result  : aliased Signature;
      Length  : aliased size_t := Result'Length;
      Status  : int := 0;
   begin
      if Context /= Null_Address
        and then EVP_DigestSignInit (Context, Null_Address, Null_Address, Null_Address, Pair) = 1
      then
         Status := EVP_DigestSign (Context, Result'Address, Length'Access, Start_Of (Message), Message'Length);
      end if;
      EVP_MD_CTX_free (Context);
      EVP_PKEY_free (Pair);
      if Status /= 1 or else Length /= Result'Length then
         Fail ("EVP_DigestSign");
      end if;
      return Result;
   end Sign;

   function Verify (Key : Public_Key; Message : String; Signed : String) return Boolean is
      Public  : Address;
      Context : Address;
      Status  : int := 0;
   begin
      if Signed'Length /= Signature'Length then
         return False;
      end if;
      Public := EVP_PKEY_new_raw_public_key (EVP_PKEY_ED25519, Null_Address, Key'Address, 32);
      if Public = Null_Address then
         Clear_Errors;
         return False;
      end if;
      Context := EVP_MD_CTX_new;
      if Context /= Null_Address
        and then EVP_DigestVerifyInit (Context, Null_Address, Null_Address, Null_Address, Public) = 1
      then
         Status := EVP_DigestVerify (Context, Signed'Address, Signed'Length, Start_Of (Message), Message'Length);
      end if;
      EVP_MD_CTX_free (Context);
      EVP_PKEY_free (Public);
      if Status /= 1 then
         Clear_Errors;
      end if;
      return Status = 1;
   end Verify;

end Sparrow.Crypto.Signatures;
