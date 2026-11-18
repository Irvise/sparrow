with Interfaces.C; use Interfaces.C;
with Sparrow.Crypto.Hashes;
with Sparrow.Crypto.Libcrypto; use Sparrow.Crypto.Libcrypto;
with System; use System;

package body Sparrow.Crypto.Macs with SPARK_Mode => Off is

   function C_Hmac
     (Kind : Address; Key : Address; Key_Length : int; Data : Address; Count : size_t; Into : Address;
      Size : access unsigned) return Address
      with Import, Convention => C, External_Name => "HMAC";

   function Hmac (Algorithm : Digest_Algorithm; Secret : String; Data : String) return String is
      Result : aliased String (1 .. Digest_Length (Algorithm));
      Size   : aliased unsigned := 0;
   begin
      if Secret'Length > Max_Secret then   --  what HMAC would do itself; keeps the length within an int
         return Hmac (Algorithm, Hashes.Hash (Algorithm, Secret), Data);
      end if;
      if C_Hmac (Digest_Of (Algorithm), Start_Of (Secret), int (Secret'Length), Start_Of (Data), Data'Length,
                 Result'Address, Size'Access) = Null_Address
        or else Size /= Result'Length
      then
         Fail ("HMAC");
      end if;
      return Result;
   end Hmac;

   function To_Hmac_Key (Algorithm : Digest_Algorithm; Secret : String) return Hmac_Key is
      Kept : constant String := (if Secret'Length > Max_Secret then Hashes.Hash (Algorithm, Secret) else Secret);
      Key  : Hmac_Key := (Algorithm => Algorithm, Length => Kept'Length, others => <>);
   begin
      Key.Secret (1 .. Kept'Length) := Kept;
      return Key;
   end To_Hmac_Key;

   function Hmac (Key : Hmac_Key; Data : String) return String is
     (Hmac (Key.Algorithm, Key.Secret (1 .. Key.Length), Data));

end Sparrow.Crypto.Macs;
