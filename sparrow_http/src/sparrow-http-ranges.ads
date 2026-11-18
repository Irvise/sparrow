--  The Range request header (RFC 9110 14.2): one range of bytes, as players seek in a video and downloads
--  resume. A request for several ranges at once gets the whole representation, which RFC 9110 allows, and
--  so does a header this cannot read.
--
--  SPARK: no run-time errors, and a Part lies inside the representation.
package Sparrow.Http.Ranges with SPARK_Mode is

   subtype Byte_Count is Long_Long_Integer range 0 .. 2 ** 62;

   --  Whole: answer as if there were no Range (200). Part: the bytes First .. Last (206). Unsatisfiable: no
   --  byte of the representation is in the range (416).
   type Range_Kind is (Whole, Part, Unsatisfiable);

   type Byte_Range is record
      Kind  : Range_Kind := Whole;
      First : Byte_Count := 0;
      Last  : Byte_Count := 0;
   end record;

   --  Header: the Range header's value ("bytes=0-499", "bytes=500-", "bytes=-500"); Size: the representation's
   --  length in bytes.
   function Parse (Header : String; Size : Byte_Count) return Byte_Range
      with Post => (if Parse'Result.Kind = Part
                    then Parse'Result.First <= Parse'Result.Last and then Parse'Result.Last < Size);

end Sparrow.Http.Ranges;
