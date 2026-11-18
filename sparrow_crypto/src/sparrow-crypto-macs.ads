--  HMAC (RFC 2104) over any digest.
package Sparrow.Crypto.Macs with SPARK_Mode is

   function Hmac (Algorithm : Digest_Algorithm; Secret : String; Data : String) return String
      with Post => Hmac'Result'First = 1 and then Hmac'Result'Length = Digest_Length (Algorithm);

   --  A secret bound to its digest, to keep in a record (a JWT key, a cookie signer). No storage to free.
   type Hmac_Key is private;

   function To_Hmac_Key (Algorithm : Digest_Algorithm; Secret : String) return Hmac_Key;
   function Algorithm_Of (Key : Hmac_Key) return Digest_Algorithm;

   function Hmac (Key : Hmac_Key; Data : String) return String
      with Post => Hmac'Result'First = 1 and then Hmac'Result'Length = Digest_Length (Algorithm_Of (Key));

private

   --  HMAC hashes a secret longer than the digest's block; one that long is stored hashed, which gives the
   --  same MACs. 144 is the largest block (SHA3-256: 136).
   Max_Secret : constant := 144;

   type Hmac_Key is record
      Algorithm : Digest_Algorithm := Sha256;
      Length    : Natural range 0 .. Max_Secret := 0;
      Secret    : String (1 .. Max_Secret) := [others => ASCII.NUL];
   end record;

   function Algorithm_Of (Key : Hmac_Key) return Digest_Algorithm is (Key.Algorithm);

end Sparrow.Crypto.Macs;
