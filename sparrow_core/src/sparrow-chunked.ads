--  HTTP/1.1 chunked bodies (RFC 9112 7.1), decoded as they arrive: give Decode the bytes received so far, and
--  it consumes framing and hands back the body's bytes as spans of them, one run at a time. Call it again with
--  the rest until it has consumed everything (or wants more), or it is Done or Failed. Chunk extensions and
--  trailer fields are read and dropped.
--
--  SPARK: Decode cannot raise or read outside what it is given on any input.
with Sparrow.Encoding; use Sparrow.Encoding;

package Sparrow.Chunked with SPARK_Mode is

   --  A body's length: streamed bodies may pass 2 GiB.
   subtype Body_Size is Long_Long_Integer range 0 .. 2 ** 62;

   type Decoder_State is
     (Size_Start, Size, Extension, Size_End, Data, Data_End, Data_End_Line, Trailer_Start, Trailer,
      Trailer_Line_End, Final_Line_End, Done, Failed);

   type Decoder is record
      State         : Decoder_State := Size_Start;
      Remaining     : Body_Size := 0;   --  bytes of the current chunk still to come
      Decoded       : Body_Size := 0;   --  body bytes so far
      Framing       : Natural := 0;     --  bytes of sizes, extensions and trailers so far
      Body_Limit    : Body_Size := 0;
      Framing_Limit : Natural := 0;
      Too_Large     : Boolean := False;   --  when Failed: past a limit, not malformed
   end record;

   Largest_Body : constant := Body_Size'Last - 16;

   --  A decoder for a body of at most Max_Body_Length bytes, framed by at most Max_Framing more.
   function New_Decoder (Max_Body_Length : Body_Size; Max_Framing : Natural) return Decoder is
     ((State => Size_Start, Remaining => 0, Decoded => 0, Framing => 0, Body_Limit => Max_Body_Length,
       Framing_Limit => Max_Framing, Too_Large => False))
     with Pre => Max_Body_Length <= Largest_Body;

   function Valid (This : Decoder) return Boolean is
     (This.Body_Limit <= Largest_Body
      and then This.Decoded <= This.Body_Limit
      and then This.Framing <= This.Framing_Limit
      and then (if This.State in Extension | Size_End | Data
                then This.Remaining <= This.Body_Limit - This.Decoded)
      and then (if This.State = Data then This.Remaining > 0)
      and then (if This.State = Size then This.Remaining <= This.Body_Limit + 15));

   --  Consumed is how many bytes of Received were used, from its start; Content, when not empty, is body bytes
   --  among them.
   procedure Decode (This : in out Decoder; Received : String; Consumed : out Natural; Content : out Span)
     with Pre  => Valid (This) and then Received'Last < Positive'Last,
          Post => Valid (This)
                  and then Consumed <= Received'Length
                  and then Within (Content, Received)
                  and then (Length (Content) = 0 or else Content.Last < Received'First + Consumed)
                  and then (if This.State not in Done | Failed and then Length (Content) = 0
                            then Consumed = Received'Length)
                  and then (if This'Old.State in Done | Failed then Consumed = 0 and then This = This'Old);

end Sparrow.Chunked;
