--  Random bytes from OpenSSL's generator (RAND_bytes, seeded by the system): salts, nonces, keys, session
--  identifiers.
package Sparrow.Crypto.Random
  with SPARK_Mode, Abstract_State => (Entropy with Synchronous, External), Initializes => Entropy
is

   procedure Fill (Into : out String) with Global => (In_Out => Entropy);

   --  Count random bytes as Url_Safe Base64 without padding: a token safe in a URL, cookie or header.
   procedure Token (Byte_Count : Positive; Into : out String; Last : out Natural)
      with Global => (In_Out => Entropy),
           Pre    => Byte_Count <= 1024 and then Into'First = 1 and then Into'Length >= (Byte_Count + 2) / 3 * 4,
           Post   => Last <= Into'Last;

end Sparrow.Crypto.Random;
