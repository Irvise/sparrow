--  gzip (RFC 1952): DEFLATE with a header and a CRC-32 trailer, as HTTP's Content-Encoding: gzip carries it.
--
--  SPARK: no run-time errors, and nothing is written outside Output.
with Interfaces; use Interfaces;
with Sparrow.Deflate;

package Sparrow.Gzip with SPARK_Mode is

   --  Bytes a gzip member adds around its DEFLATE data, padding aside.
   Overhead : constant := 18;

   --  Input as one gzip member in Output (Output'First .. Last); Fits is False when it does not fit. Padding
   --  bytes go into the header's file-name field, which decoders skip: a random amount makes the length of a
   --  compressed response a worse guide to its content (a defense against BREACH-style guessing).
   procedure Compress
     (Work    : in out Deflate.State;
      Input   : String;
      Output  : in out String;
      Last    : out Natural;
      Fits    : out Boolean;
      Padding : Natural := 0)
      with Pre  => Input'First >= 1 and then Input'Last < Positive'Last - 512 and then Input'Last >= Input'First - 1
                   and then Output'First >= 1
                   and then Output'Last < Positive'Last - 1 and then Output'Last >= Output'First - 1
                   and then Padding <= 255,
           Post => Last in Output'First - 1 .. Output'Last;

   --  The CRC-32 of Data (ISO 3309, as gzip, zlib and PNG use it), continued from Previous.
   function Crc_32 (Data : String; Previous : Unsigned_32 := 0) return Unsigned_32;

end Sparrow.Gzip;
