with Interfaces.C; use Interfaces.C;
with Sparrow.Crypto.Libcrypto; use Sparrow.Crypto.Libcrypto;
with System; use System;

package body Sparrow.Crypto.Ciphers with SPARK_Mode => Off is

   function EVP_aes_256_gcm return Address with Import, Convention => C, External_Name => "EVP_aes_256_gcm";
   function EVP_chacha20_poly1305 return Address
      with Import, Convention => C, External_Name => "EVP_chacha20_poly1305";
   function EVP_CIPHER_CTX_new return Address with Import, Convention => C, External_Name => "EVP_CIPHER_CTX_new";
   procedure EVP_CIPHER_CTX_free (Context : Address)
      with Import, Convention => C, External_Name => "EVP_CIPHER_CTX_free";
   function EVP_CIPHER_CTX_ctrl (Context : Address; Kind : int; Argument : int; Data : Address) return int
      with Import, Convention => C, External_Name => "EVP_CIPHER_CTX_ctrl";
   function EVP_CipherInit_ex
     (Context : Address; Cipher : Address; Engine : Address; Key : Address; Nonce : Address; Encrypt : int)
      return int
      with Import, Convention => C, External_Name => "EVP_CipherInit_ex";
   function EVP_CipherUpdate
     (Context : Address; Into : Address; Written : access int; From : Address; Count : int) return int
      with Import, Convention => C, External_Name => "EVP_CipherUpdate";
   function EVP_CipherFinal_ex (Context : Address; Into : Address; Written : access int) return int
      with Import, Convention => C, External_Name => "EVP_CipherFinal_ex";

   EVP_CTRL_AEAD_GET_TAG : constant := 16#10#;
   EVP_CTRL_AEAD_SET_TAG : constant := 16#11#;

   function Cipher_Of (Algorithm : Aead_Algorithm) return Address is
     (case Algorithm is when Aes_256_Gcm => EVP_aes_256_gcm, when Chacha20_Poly1305 => EVP_chacha20_poly1305);

   --  A context set up for one message: key, nonce (both ciphers default to 12 bytes) and associated data.
   function Start
     (Algorithm : Aead_Algorithm; Key : Key_Bytes; Nonce : Nonce_Bytes; Associated : String; Encrypt : Boolean)
      return Address
   is
      Context : constant Address := EVP_CIPHER_CTX_new;
      Written : aliased int := 0;
   begin
      if Context = Null_Address then
         Fail ("EVP_CIPHER_CTX_new");
      end if;
      if EVP_CipherInit_ex (Context, Cipher_Of (Algorithm), Null_Address, Key'Address, Nonce'Address,
                            (if Encrypt then 1 else 0)) /= 1
        or else (Associated'Length > 0
                 and then EVP_CipherUpdate (Context, Null_Address, Written'Access, Associated'Address,
                                            int (Associated'Length)) /= 1)
      then
         EVP_CIPHER_CTX_free (Context);
         Fail ("EVP_CipherInit_ex");
      end if;
      return Context;
   end Start;

   function Seal
     (Algorithm  : Aead_Algorithm;
      Key        : Key_Bytes;
      Nonce      : Nonce_Bytes;
      Plain      : String;
      Associated : String := "") return String
   is
      Context : constant Address := Start (Algorithm, Key, Nonce, Associated, Encrypt => True);
      Result  : aliased String (1 .. Plain'Length + Tag_Length) := [others => ASCII.NUL];
      Written : aliased int := 0;
      Final   : aliased int := 0;
   begin
      if (Plain'Length > 0
          and then EVP_CipherUpdate (Context, Result'Address, Written'Access, Plain'Address, int (Plain'Length)) /= 1)
        or else EVP_CipherFinal_ex (Context, Result (Natural (Written) + 1)'Address, Final'Access) /= 1
        or else Natural (Written + Final) /= Plain'Length
        or else EVP_CIPHER_CTX_ctrl (Context, EVP_CTRL_AEAD_GET_TAG, Tag_Length,
                                     Result (Plain'Length + 1)'Address) /= 1
      then
         EVP_CIPHER_CTX_free (Context);
         Fail ("AEAD seal");
      end if;
      EVP_CIPHER_CTX_free (Context);
      return Result;
   end Seal;

   procedure Open
     (Algorithm  : Aead_Algorithm;
      Key        : Key_Bytes;
      Nonce      : Nonce_Bytes;
      Sealed     : String;
      Plain      : out String;
      Last       : out Natural;
      Valid      : out Boolean;
      Associated : String := "")
   is
      Context : Address;
      Length  : constant Integer := Sealed'Length - Tag_Length;
      Tag     : aliased String (1 .. Tag_Length);
      Written : aliased int := 0;
      Final   : aliased int := 0;
      Spare   : aliased String (1 .. 16);   --  where a final block would go; AEAD ciphers write none
   begin
      Plain := [others => ASCII.NUL];
      Last  := 0;
      Valid := False;
      if Length < 0 then
         return;
      end if;
      Tag     := Sealed (Sealed'Last - Tag_Length + 1 .. Sealed'Last);
      Context := Start (Algorithm, Key, Nonce, Associated, Encrypt => False);
      Valid :=
        (Length = 0
         or else EVP_CipherUpdate (Context, Plain'Address, Written'Access, Sealed'Address, int (Length)) = 1)
        and then EVP_CIPHER_CTX_ctrl (Context, EVP_CTRL_AEAD_SET_TAG, Tag_Length, Tag'Address) = 1
        and then EVP_CipherFinal_ex (Context, Spare'Address, Final'Access) = 1   --  checks the tag
        and then Natural (Written) = Length;
      EVP_CIPHER_CTX_free (Context);
      if Valid then
         Last := Length;
      else
         Plain := [others => ASCII.NUL];   --  nothing unauthenticated leaves
         Clear_Errors;
      end if;
   end Open;

end Sparrow.Crypto.Ciphers;
