package body Sparrow.Valkey_Protocol with SPARK_Mode is

   CRLF : constant String := [ASCII.CR, ASCII.LF];

   --  The CR of the first CRLF at or after From; 0 when there is none.
   function Line_End (Data : String; From : Positive) return Natural
      with Pre  => Data'Last < Positive'Last - 2 and then From >= Data'First,
           Post => Line_End'Result = 0
                   or else (Line_End'Result in From .. Data'Last - 1 and then Data (Line_End'Result) = ASCII.CR
                            and then Data (Line_End'Result + 1) = ASCII.LF)
   is begin
      if From > Data'Last then
         return 0;
      end if;
      for Index in From .. Data'Last - 1 loop
         if Data (Index) = ASCII.CR and then Data (Index + 1) = ASCII.LF then
            return Index;
         end if;
      end loop;
      return 0;
   end Line_End;

   type Parsed_Number (Valid : Boolean := False) is record
      case Valid is
         when True  => Value : Long_Long_Integer;
         when False => null;
      end case;
   end record;

   --  An optional '-' then 1 to 18 digits.
   function Number_Of (Text : String) return Parsed_Number
      with Pre => Text'First >= 1 and then Text'Last < Positive'Last
   is
      Negative : constant Boolean := Text'Length > 0 and then Text (Text'First) = '-';
      First    : constant Natural := (if Negative then Text'First + 1 else Text'First);
      Value    : Long_Long_Integer := 0;
   begin
      if Text'Length = 0 or else First > Text'Last or else Text'Last - First + 1 > 18 then
         return (Valid => False);
      end if;
      for Index in First .. Text'Last loop
         pragma Loop_Invariant (Value >= 0);
         if Text (Index) not in '0' .. '9' or else Value > (Long_Long_Integer'Last - 9) / 10 then
            return (Valid => False);
         end if;
         Value := Value * 10 + Long_Long_Integer (Character'Pos (Text (Index)) - Character'Pos ('0'));
      end loop;
      return (Valid => True, Value => (if Negative then -Value else Value));
   end Number_Of;

   function Element_At (Data : String; Position : Positive) return Element is
      Malformed_Element  : constant Element := (Kind => Malformed, others => <>);
      Incomplete_Element : constant Element := (Kind => Incomplete, others => <>);
      Last_Line          : constant Natural := (if Position < Data'Last then Line_End (Data, Position + 1) else 0);
   begin
      if Data (Position) not in '+' | '-' | ':' | '$' | '*' then
         return Malformed_Element;
      elsif Last_Line = 0 then
         return Incomplete_Element;
      end if;

      declare
         Line : constant Span := (First => Position + 1, Last => Last_Line - 1);
         Next : constant Positive := Last_Line + 2;   --  after the line's CRLF
      begin
         case Data (Position) is
            when '+' =>
               return (Kind => Simple_Text, Text => Line, Number => 0, Next => Next);
            when '-' =>
               return (Kind => Error_Text, Text => Line, Number => 0, Next => Next);
            when ':' =>
               declare
                  Value : constant Parsed_Number := Number_Of (Data (Position + 1 .. Last_Line - 1));
               begin
                  if not Value.Valid then
                     return Malformed_Element;
                  end if;
                  return (Kind => Whole_Number, Text => Empty, Number => Value.Value, Next => Next);
               end;
            when '$' | '*' =>
               declare
                  Count : constant Parsed_Number := Number_Of (Data (Position + 1 .. Last_Line - 1));
               begin
                  if not Count.Valid or else Count.Value < -1 then
                     return Malformed_Element;
                  elsif Count.Value = -1 then
                     return (Kind => Nil, Text => Empty, Number => 0, Next => Next);
                  elsif Data (Position) = '*' then
                     if Count.Value > Max_Elements then
                        return Malformed_Element;
                     end if;
                     return (Kind => List, Text => Empty, Number => Count.Value, Next => Next);
                  elsif Count.Value > Max_Bulk_Length then
                     return Malformed_Element;
                  elsif Next > Data'Last or else Long_Long_Integer (Data'Last - Next) < Count.Value + 1 then
                     return Incomplete_Element;   --  the text and its CRLF are not all here
                  end if;
                  declare
                     Text_Last : constant Natural := Next + Natural (Count.Value) - 1;
                  begin
                     if Data (Text_Last + 1 .. Text_Last + 2) /= CRLF then
                        return Malformed_Element;
                     end if;
                     return (Kind => Bulk_Text, Text => (First => Next, Last => Text_Last), Number => 0,
                             Next => Text_Last + 3);
                  end;
               end;
            when others =>
               return Malformed_Element;
         end case;
      end;
   end Element_At;

   function Scan (Data : String) return Scan_Result is
      Position : Positive := Data'First;
      Pending  : Long_Long_Integer := 1;   --  elements still to read
      Total    : Long_Long_Integer := 0;   --  elements the lists have announced
   begin
      if Data'Length = 0 then
         return (Outcome => Waiting);
      end if;
      loop
         pragma Loop_Invariant (Position in Data'Range and then Pending in 1 .. Max_Elements + 1
                                and then Total in 0 .. Max_Elements);
         pragma Loop_Variant (Increases => Position);
         declare
            Item : constant Element := Element_At (Data, Position);
         begin
            case Item.Kind is
               when Incomplete =>
                  return (Outcome => Waiting);
               when Malformed =>
                  return (Outcome => Refused);
               when List =>
                  if Item.Number > Max_Elements - Total then
                     return (Outcome => Refused);
                  end if;
                  Total   := Total + Item.Number;
                  Pending := Pending - 1 + Item.Number;
               when others =>
                  Pending := Pending - 1;
            end case;
            if Pending = 0 then
               return (Outcome => Complete, Length => Item.Next - Data'First);
            elsif Item.Next > Data'Last then
               return (Outcome => Waiting);
            elsif Pending > Max_Elements + 1 then
               return (Outcome => Refused);
            end if;
            Position := Item.Next;
         end;
      end loop;
   end Scan;

   function Header (Count : Positive) return String is
     ("*" & Decimal_Image (Long_Long_Integer (Count)) & CRLF);

   procedure Append_Argument (To : in out Buffer; Argument : String) is begin
      Append (To, "$" & Decimal_Image (Long_Long_Integer (Argument'Length)) & CRLF);
      Append (To, Argument);
      Append (To, CRLF);
   end Append_Argument;

end Sparrow.Valkey_Protocol;
