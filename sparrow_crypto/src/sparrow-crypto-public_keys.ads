--  Public-key signatures as JSON Web Tokens use them: RSA with SHA-256 (RS256, PKCS #1 v1.5), ECDSA on P-256 with
--  SHA-256 (ES256) and Ed25519 (EdDSA). Keys come from the parts a JWK carries, or from PEM.
--
--  A key is a reference to OpenSSL's: copying one is cheap, and a key may be used by several tasks at once.
--  Building a key from bad parts gives an invalid key, not an exception: check Is_Valid.
private with Ada.Finalization;
private with System;

package Sparrow.Crypto.Public_Keys is

   type Key_Kind is
     (None,      --  an invalid key
      Rsa,       --  2048 bits or more; fewer are refused
      Ec_P256,
      Ed25519);

   ---------------------------------------------------------------------------------------------------------------
   --  Verifying

   type Public_Key is private;

   No_Public_Key : constant Public_Key;

   function Kind (Key : Public_Key) return Key_Kind;
   function Is_Valid (Key : Public_Key) return Boolean is (Kind (Key) /= None);

   --  From a JWK's parts, as bytes (big-endian numbers): RSA's n and e, P-256's x and y (32 bytes each),
   --  Ed25519's x (32 bytes).
   function Rsa_Key (Modulus, Exponent : String) return Public_Key;
   function Ec_P256_Key (X, Y : String) return Public_Key;
   function Ed25519_Key (X : String) return Public_Key;

   --  From PEM: "-----BEGIN PUBLIC KEY-----" (SubjectPublicKeyInfo) of any of the kinds above.
   function From_Pem (Text : String) return Public_Key;

   --  Whether Signed is Key's signature of Message: RSA's as it is, P-256's as the 64 bytes r then s (as in a
   --  JWS, not DER), Ed25519's 64 bytes. False for an invalid key.
   function Verify (Key : Public_Key; Message : String; Signed : String) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  Signing, for tokens that others verify with the public key

   type Private_Key is private;

   function Kind (Key : Private_Key) return Key_Kind;
   function Is_Valid (Key : Private_Key) return Boolean is (Kind (Key) /= None);

   --  From PEM: "-----BEGIN PRIVATE KEY-----" (PKCS #8, unencrypted) of any of the kinds above.
   function Private_From_Pem (Text : String) return Private_Key;

   --  From an Ed25519 seed (32 bytes, as Sparrow.Crypto.Signatures takes).
   function Ed25519_Private (Seed : String) return Private_Key;

   function Public_Of (Key : Private_Key) return Public_Key
      with Pre => Is_Valid (Key);

   --  Key's signature of Message, in the form Verify takes. Crypto_Error when OpenSSL fails.
   function Sign (Key : Private_Key; Message : String) return String
      with Pre => Is_Valid (Key);

private

   --  An EVP_PKEY, counted: Adjust takes a reference, Finalize gives one back.
   type Key_Reference is new Ada.Finalization.Controlled with record
      Handle : System.Address := System.Null_Address;
      Kind   : Key_Kind := None;
   end record;

   overriding procedure Adjust (This : in out Key_Reference);
   overriding procedure Finalize (This : in out Key_Reference);

   No_Reference : constant Key_Reference := (Ada.Finalization.Controlled with Handle => System.Null_Address,
                                             Kind => None);

   type Public_Key is record
      Reference : Key_Reference;
   end record;

   type Private_Key is record
      Reference : Key_Reference;
   end record;

   No_Public_Key : constant Public_Key :=
     (Reference => (Ada.Finalization.Controlled with Handle => System.Null_Address, Kind => None));

end Sparrow.Crypto.Public_Keys;
