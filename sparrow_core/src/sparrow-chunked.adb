package body Sparrow.Chunked with SPARK_Mode is

   function Hex_Value (Symbol : Character) return Natural is
     (case Symbol is
         when '0' .. '9' => Character'Pos (Symbol) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Symbol) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Symbol) - Character'Pos ('A') + 10,
         when others     => 0)
     with Post => Hex_Value'Result <= 15;

   procedure Decode (This : in out Decoder; Received : String; Consumed : out Natural; Content : out Span) is
      Position : Positive;   --  the next byte to look at

      procedure Fail (Too_Large : Boolean) is begin
         This.State     := Failed;
         This.Too_Large := Too_Large;
      end Fail;
   begin
      Content  := Empty;
      Consumed := 0;
      if Received'Length = 0 or else This.State in Done | Failed then
         return;
      end if;
      Position := Received'First;
      loop
         pragma Loop_Invariant (Valid (This) and then Position in Received'Range and then Length (Content) = 0);
         pragma Loop_Variant (Increases => Position);

         if This.State = Data then
            declare
               Run : constant Positive :=
                 Positive (Body_Size'Min (This.Remaining, Body_Size (Received'Last - Position + 1)));
            begin
               Content         := (First => Position, Last => Position + Run - 1);
               This.Remaining  := This.Remaining - Body_Size (Run);
               This.Decoded    := This.Decoded + Body_Size (Run);
               if This.Remaining = 0 then
                  This.State := Data_End;
               end if;
               Consumed := Content.Last - Received'First + 1;
               return;
            end;
         end if;

         --  One byte of framing.
         if This.Framing = This.Framing_Limit then
            Fail (Too_Large => True);
         else
            This.Framing := This.Framing + 1;
            declare
               Symbol : constant Character := Received (Position);
               Is_Hex : constant Boolean := Symbol in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F';
            begin
               case This.State is
                  when Size_Start =>
                     if Is_Hex then
                        This.Remaining := Body_Size (Hex_Value (Symbol));
                        This.State     := Size;
                     else
                        Fail (Too_Large => False);
                     end if;
                  when Size =>
                     if Is_Hex then
                        if This.Remaining > This.Body_Limit / 16 then
                           Fail (Too_Large => True);
                        else
                           This.Remaining := This.Remaining * 16 + Body_Size (Hex_Value (Symbol));
                        end if;
                     elsif Symbol in ';' | ' ' | ASCII.HT then
                        This.State := Extension;
                     elsif Symbol = ASCII.CR then
                        This.State := Size_End;
                     else
                        Fail (Too_Large => False);
                     end if;
                     if This.State in Extension | Size_End and then This.Remaining > This.Body_Limit - This.Decoded
                     then
                        Fail (Too_Large => True);
                     end if;
                  when Extension =>
                     if Symbol = ASCII.CR then
                        This.State := Size_End;
                     elsif Symbol = ASCII.LF then
                        Fail (Too_Large => False);
                     end if;
                  when Size_End =>
                     if Symbol /= ASCII.LF then
                        Fail (Too_Large => False);
                     elsif This.Remaining = 0 then
                        This.State := Trailer_Start;   --  the last chunk
                     else
                        This.State := Data;
                     end if;
                  when Data_End =>
                     if Symbol = ASCII.CR then
                        This.State := Data_End_Line;
                     else
                        Fail (Too_Large => False);
                     end if;
                  when Data_End_Line =>
                     if Symbol = ASCII.LF then
                        This.State := Size_Start;
                     else
                        Fail (Too_Large => False);
                     end if;
                  when Trailer_Start =>
                     if Symbol = ASCII.CR then
                        This.State := Final_Line_End;
                     elsif Symbol = ASCII.LF then
                        Fail (Too_Large => False);
                     else
                        This.State := Trailer;
                     end if;
                  when Trailer =>
                     if Symbol = ASCII.CR then
                        This.State := Trailer_Line_End;
                     elsif Symbol = ASCII.LF then
                        Fail (Too_Large => False);
                     end if;
                  when Trailer_Line_End =>
                     if Symbol = ASCII.LF then
                        This.State := Trailer_Start;
                     else
                        Fail (Too_Large => False);
                     end if;
                  when Final_Line_End =>
                     if Symbol = ASCII.LF then
                        This.State := Done;
                     else
                        Fail (Too_Large => False);
                     end if;
                  when Data | Done | Failed =>
                     null;
               end case;
            end;
         end if;
         exit when Position = Received'Last or else This.State in Done | Failed;
         Position := Position + 1;
      end loop;

      Consumed := (if This.State = Failed then Position - Received'First else Position - Received'First + 1);
   end Decode;

end Sparrow.Chunked;
