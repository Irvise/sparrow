--  Message digests (EVP_Digest).
package Sparrow.Crypto.Hashes with SPARK_Mode is

   function Hash (Algorithm : Digest_Algorithm; Data : String) return String
      with Post => Hash'Result'First = 1 and then Hash'Result'Length = Digest_Length (Algorithm);

end Sparrow.Crypto.Hashes;
