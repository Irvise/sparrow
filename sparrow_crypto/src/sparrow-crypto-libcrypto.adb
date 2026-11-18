package body Sparrow.Crypto.Libcrypto is

   Empty : aliased constant String (1 .. 1) := [1 => ASCII.NUL];

   function Start_Of (Data : String) return Address is
     (if Data'Length = 0 then Empty'Address else Data (Data'First)'Address);

   function ERR_get_error return unsigned_long with Import, Convention => C, External_Name => "ERR_get_error";
   procedure ERR_error_string_n (Code : unsigned_long; Into : Address; Length : size_t)
      with Import, Convention => C, External_Name => "ERR_error_string_n";
   procedure ERR_clear_error with Import, Convention => C, External_Name => "ERR_clear_error";

   procedure Clear_Errors is begin
      ERR_clear_error;
   end Clear_Errors;

   procedure Fail (What : String) is
      Code   : constant unsigned_long := ERR_get_error;
      Detail : aliased String (1 .. 256) := [others => ASCII.NUL];
      Last   : Natural := 0;
   begin
      if Code /= 0 then
         ERR_error_string_n (Code, Detail'Address, Detail'Length);
         while Last < Detail'Last and then Detail (Last + 1) /= ASCII.NUL loop
            Last := Last + 1;
         end loop;
      end if;
      ERR_clear_error;
      raise Crypto_Error with What & (if Last = 0 then "" else ": " & Detail (1 .. Last));
   end Fail;

   function EVP_sha256     return Address with Import, Convention => C, External_Name => "EVP_sha256";
   function EVP_sha384     return Address with Import, Convention => C, External_Name => "EVP_sha384";
   function EVP_sha512     return Address with Import, Convention => C, External_Name => "EVP_sha512";
   function EVP_sha3_256   return Address with Import, Convention => C, External_Name => "EVP_sha3_256";
   function EVP_sha1       return Address with Import, Convention => C, External_Name => "EVP_sha1";
   function EVP_blake2b512 return Address with Import, Convention => C, External_Name => "EVP_blake2b512";

   function Digest_Of (Algorithm : Digest_Algorithm) return Address is
     (case Algorithm is
         when Sha256      => EVP_sha256,
         when Sha384      => EVP_sha384,
         when Sha512      => EVP_sha512,
         when Sha3_256    => EVP_sha3_256,
         when Blake2b_512 => EVP_blake2b512,
         when Sha1        => EVP_sha1);

   function Name_Of (Algorithm : Digest_Algorithm) return String is
     ((case Algorithm is
          when Sha256      => "SHA2-256",
          when Sha384      => "SHA2-384",
          when Sha512      => "SHA2-512",
          when Sha3_256    => "SHA3-256",
          when Blake2b_512 => "BLAKE2B-512",
          when Sha1        => "SHA1") & ASCII.NUL);

   function EVP_KDF_fetch (Library, Name, Properties : Address) return Address
      with Import, Convention => C, External_Name => "EVP_KDF_fetch";
   procedure EVP_KDF_free (Kdf : Address) with Import, Convention => C, External_Name => "EVP_KDF_free";
   function EVP_KDF_CTX_new (Kdf : Address) return Address
      with Import, Convention => C, External_Name => "EVP_KDF_CTX_new";
   procedure EVP_KDF_CTX_free (Context : Address)
      with Import, Convention => C, External_Name => "EVP_KDF_CTX_free";
   function EVP_KDF_derive (Context : Address; Key : Address; Length : size_t; Parameters : Address) return int
      with Import, Convention => C, External_Name => "EVP_KDF_derive";

   function Has_Kdf (Name : String) return Boolean is
      Kdf : constant Address := EVP_KDF_fetch (Null_Address, Name'Address, Null_Address);
   begin
      if Kdf = Null_Address then
         ERR_clear_error;   --  the failed fetch queued an error
         return False;
      end if;
      EVP_KDF_free (Kdf);
      return True;
   end Has_Kdf;

   function Derive (Name : String; Parameters : Parameter_List; Length : Positive) return String is
      Kdf     : constant Address := EVP_KDF_fetch (Null_Address, Name'Address, Null_Address);
      Context : Address;
      Result  : aliased String (1 .. Length);
      Status  : int;
   begin
      if Kdf = Null_Address then
         Fail ("EVP_KDF_fetch " & Name (Name'First .. Name'Last - 1));
      end if;
      Context := EVP_KDF_CTX_new (Kdf);
      EVP_KDF_free (Kdf);   --  the context holds its own reference
      if Context = Null_Address then
         Fail ("EVP_KDF_CTX_new");
      end if;
      Status := EVP_KDF_derive (Context, Result'Address, size_t (Length), Parameters'Address);
      EVP_KDF_CTX_free (Context);
      if Status /= 1 then
         Fail ("EVP_KDF_derive " & Name (Name'First .. Name'Last - 1));
      end if;
      return Result;
   end Derive;

end Sparrow.Crypto.Libcrypto;
