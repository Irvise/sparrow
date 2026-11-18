with Sparrow.Encoding;

package body Sparrow.Http.Ranges with SPARK_Mode is

   --  Digits as a number, held at Byte_Count'Last when larger; Valid is False for anything but digits.
   procedure Read_Number (Text : String; Value : out Byte_Count; Valid : out Boolean) is
   begin
      Value := 0;
      Valid := Text'Length > 0;
      for Symbol of Text loop
         if Symbol not in '0' .. '9' then
            Valid := False;
            Value := 0;
            return;
         end if;
         Value := (if Value > (Byte_Count'Last - 9) / 10 then Byte_Count'Last
                   else Value * 10 + (Character'Pos (Symbol) - Character'Pos ('0')));
      end loop;
   end Read_Number;

   function Parse (Header : String; Size : Byte_Count) return Byte_Range is
      Unit  : constant String := "bytes=";
      First : Positive;
      Last  : Natural;
   begin
      if Header'Length = 0 or else Header'Last = Integer'Last then
         return (Kind => Whole, others => 0);
      end if;
      First := Header'First;
      Last  := Header'Last;
      while First <= Last and then Header (First) = ' ' loop
         pragma Loop_Invariant (First in Header'First .. Last);
         pragma Loop_Variant (Increases => First);
         First := First + 1;
      end loop;
      while Last >= First and then Header (Last) = ' ' loop
         pragma Loop_Invariant (Last in First .. Header'Last);
         pragma Loop_Variant (Decreases => Last);
         Last := Last - 1;
      end loop;
      if Last - First + 1 < Unit'Length + 1
        or else not Encoding.Equal_Ignoring_Case (Header (First .. First + Unit'Length - 1), Unit)
      then
         return (Kind => Whole, others => 0);
      end if;

      declare
         Spec : constant String := Header (First + Unit'Length .. Last);
         Dash : Natural := 0;
      begin
         for Index in Spec'Range loop
            if Spec (Index) = ',' then
               return (Kind => Whole, others => 0);   --  several ranges
            elsif Spec (Index) = '-' and then Dash = 0 then
               Dash := Index;
            end if;
            pragma Loop_Invariant (Dash = 0 or else Dash in Spec'First .. Index);
         end loop;
         if Dash = 0 then
            return (Kind => Whole, others => 0);
         end if;

         declare
            Start_Text : constant String := Spec (Spec'First .. Dash - 1);
            End_Text   : constant String := Spec (Dash + 1 .. Spec'Last);
            Start, Stop : Byte_Count;
            Start_Valid, Stop_Valid : Boolean;
         begin
            Read_Number (Start_Text, Start, Start_Valid);
            Read_Number (End_Text, Stop, Stop_Valid);
            if Start_Text'Length = 0 then
               --  The last Stop bytes.
               if not Stop_Valid then
                  return (Kind => Whole, others => 0);
               elsif Stop = 0 or else Size = 0 then
                  return (Kind => Unsatisfiable, others => 0);
               end if;
               declare
                  From : constant Byte_Count := (if Stop >= Size then 0 else Size - Stop);
               begin
                  pragma Assert (From <= Size - 1);
                  return (Kind => Part, First => From, Last => Size - 1);
               end;
            elsif not Start_Valid or else (End_Text'Length > 0 and then (not Stop_Valid or else Stop < Start)) then
               return (Kind => Whole, others => 0);
            elsif Start >= Size then
               return (Kind => Unsatisfiable, others => 0);
            end if;
            declare
               To : constant Byte_Count := (if End_Text'Length = 0 or else Stop >= Size then Size - 1 else Stop);
            begin
               pragma Assert (Start < Size and then To < Size);
               pragma Assert (Start <= To);
               return (Kind => Part, First => Start, Last => To);
            end;
         end;
      end;
   end Parse;

end Sparrow.Http.Ranges;
