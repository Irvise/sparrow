with Interfaces; use Interfaces;

package body Sparrow.Http.Frames with SPARK_Mode is

   function Read_Head (Data : String; Largest : Natural) return Frame_Head is
      First  : Natural;
      Second : Natural;
      Final  : Boolean;
      Kind   : Opcode;
      Header : Positive := 2;
      Length : Natural;
   begin
      if Data'Length < 2 then
         return (Outcome => Short);
      end if;
      First  := Character'Pos (Data (1));
      Second := Character'Pos (Data (2));
      Final  := First >= 16#80#;
      Kind   := First mod 16;
      if First / 16 mod 8 /= 0 or else Second < 16#80# then
         return (Outcome => Refused, Close_Code => 1002);   --  reserved bits, or a client frame not masked
      end if;

      Length := Second mod 128;
      if Length = 126 then
         if Data'Length < 4 then
            return (Outcome => Short);
         end if;
         Length := Character'Pos (Data (3)) * 256 + Character'Pos (Data (4));
         Header := 4;
      elsif Length = 127 then
         if Data'Length < 10 then
            return (Outcome => Short);
         end if;
         declare
            Wide : Unsigned_64 := 0;
         begin
            for Index in 3 .. 10 loop
               exit when Wide > Unsigned_64 (Largest);   --  already too big: stop before it can overflow
               pragma Loop_Invariant (Wide <= Unsigned_64 (Largest));
               Wide := Wide * 256 + Unsigned_64 (Character'Pos (Data (Index)));
            end loop;
            if Wide > Unsigned_64 (Largest) then
               return (Outcome => Refused, Close_Code => 1009);
            end if;
            Length := Natural (Wide);
         end;
         Header := 10;
      end if;

      if Length > Largest then
         return (Outcome => Refused, Close_Code => 1009);
      elsif Kind >= Close and then (Length > 125 or else not Final) then
         return (Outcome => Refused, Close_Code => 1002);   --  a control frame must be whole and short
      end if;
      return (Outcome        => Whole_Head,
              Final          => Final,
              Kind           => Kind,
              Payload_First  => Header + 5,
              Payload_Length => Length);
   end Read_Head;

   function Unmasked (Data : String; Head : Frame_Head) return String is
      Mask   : constant Positive := Head.Payload_First - 4;
      Result : String (1 .. Head.Payload_Length);
   begin
      for Index in Result'Range loop
         Result (Index) := Character'Val
           (Unsigned_8 (Character'Pos (Data (Head.Payload_First - 1 + Index)))
            xor Unsigned_8 (Character'Pos (Data (Mask + (Index - 1) mod 4))));
      end loop;
      return Result;
   end Unmasked;

end Sparrow.Http.Frames;
