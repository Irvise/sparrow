--  Ed25519 signatures (RFC 8032): for tokens other services verify with only the public key.
package Sparrow.Crypto.Signatures with SPARK_Mode is

   subtype Private_Key is String (1 .. 32);   --  the seed; draw it with Sparrow.Crypto.Random.Fill
   subtype Public_Key is String (1 .. 32);
   subtype Signature is String (1 .. 64);

   function Public_Of (Key : Private_Key) return Public_Key;
   function Sign (Key : Private_Key; Message : String) return Signature;

   --  False for a wrong signature, a malformed one (any length but 64) or an invalid public key.
   function Verify (Key : Public_Key; Message : String; Signed : String) return Boolean;

end Sparrow.Crypto.Signatures;
