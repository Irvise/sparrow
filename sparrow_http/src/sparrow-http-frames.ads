--  WebSocket frames from clients (RFC 6455 5.2): the head read and checked, the payload unmasked. Rules that
--  span frames (continuations, a message's total size, UTF-8 of text) are the server's.
--
--  SPARK: no input makes Read_Head or Unmasked raise or read outside the data.
package Sparrow.Http.Frames with SPARK_Mode is

   subtype Opcode is Natural range 0 .. 15;

   Continuation : constant Opcode := 0;
   Text         : constant Opcode := 1;
   Binary       : constant Opcode := 2;
   Close        : constant Opcode := 8;
   Ping         : constant Opcode := 9;
   Pong         : constant Opcode := 10;

   Max_Head_Length : constant := 14;   --  2, 8 bytes of length, 4 of mask

   type Frame_Outcome is (Whole_Head, Short, Refused);

   type Frame_Head (Outcome : Frame_Outcome := Short) is record
      case Outcome is
         when Whole_Head =>
            Final          : Boolean;
            Kind           : Opcode;
            Payload_First  : Positive;   --  where the payload starts; its mask is the 4 bytes before
            Payload_Length : Natural;
         when Short =>
            null;                        --  the head has not all arrived: read more
         when Refused =>
            Close_Code : Natural;        --  1002 (protocol error) or 1009 (too big): close with it
      end case;
   end record;

   --  The head and payload together.
   function Total_Length (Head : Frame_Head) return Positive is (Head.Payload_First - 1 + Head.Payload_Length)
      with Pre => Head.Outcome = Whole_Head and then Head.Payload_First in 7 | 9 | 15
                  and then Head.Payload_Length <= Natural'Last - Max_Head_Length;

   --  The head of the frame at the start of Data. Refused: reserved bits set, an unmasked frame, a payload over
   --  Largest bytes (1009), a control frame that is fragmented or over 125 bytes. The payload need not have
   --  arrived: compare Total_Length with what has.
   function Read_Head (Data : String; Largest : Natural) return Frame_Head
      with Pre  => Data'First = 1 and then Largest <= Natural'Last - Max_Head_Length,
           Post => (case Read_Head'Result.Outcome is
                       when Whole_Head =>
                          Read_Head'Result.Payload_First in 7 | 9 | 15
                          and then Read_Head'Result.Payload_Length <= Largest
                          and then (if Read_Head'Result.Kind >= Close
                                    then Read_Head'Result.Final and then Read_Head'Result.Payload_Length <= 125),
                       when Refused    => Read_Head'Result.Close_Code in 1002 | 1009,
                       when Short      => True);

   --  The frame's payload, unmasked.
   function Unmasked (Data : String; Head : Frame_Head) return String
      with Pre  => Data'First = 1 and then Head.Outcome = Whole_Head
                   and then Head.Payload_First in 7 | 9 | 15
                   and then Head.Payload_Length <= Natural'Last - Max_Head_Length
                   and then Total_Length (Head) <= Data'Length,
           Post => Unmasked'Result'First = 1 and then Unmasked'Result'Length = Head.Payload_Length;

end Sparrow.Http.Frames;
