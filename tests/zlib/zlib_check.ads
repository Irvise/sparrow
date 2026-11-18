--  zlib's inflate, for the tests only: what Sparrow.Gzip writes is checked by the reference decoder.
package Zlib_Check is

   Not_Gzip : exception;

   --  Data as gzip decodes it (header, CRC-32 and length checked by zlib), at most Limit bytes.
   function Inflated (Data : String; Limit : Positive := 64_000_000) return String;

end Zlib_Check;
