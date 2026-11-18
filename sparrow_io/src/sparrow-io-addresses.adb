package body Sparrow.IO.Addresses with SPARK_Mode is

   subtype Four_Bytes is Byte_Array (1 .. 4);

   type Group_Array is array (1 .. 8) of Unsigned_16;

   function IPv4 (First, Second, Third, Fourth : Unsigned_8) return IP_Address is
     ((Family => Version_4, Raw => [1 => First, 2 => Second, 3 => Third, 4 => Fourth, others => 0]));

   function Bytes (Address : IP_Address) return Byte_Array is
     (if Address.Family = Version_4 then Address.Raw (1 .. 4) else Address.Raw);

   function From_Bytes (Raw : Byte_Array) return IP_Address is
      Result : IP_Address := (Family => (if Raw'Length = 4 then Version_4 else Version_6), Raw => [others => 0]);
   begin
      Result.Raw (1 .. Raw'Length) := Raw;
      return Result;
   end From_Bytes;

   function Is_Any (Address : IP_Address) return Boolean is (for all Byte of Address.Raw => Byte = 0);

   function Is_Mapped (Address : IP_Address) return Boolean is
     (Address.Family = Version_6
      and then (for all Index in 1 .. 10 => Address.Raw (Index) = 0)
      and then Address.Raw (11) = 255 and then Address.Raw (12) = 255);

   function Unmapped (Address : IP_Address) return IP_Address is
     (if Is_Mapped (Address) then From_Bytes (Address.Raw (13 .. 16)) else Address);

   ---------------------------------------------------------------------------------------------------------------
   --  reading

   function Is_Hex (Symbol : Character) return Boolean is (Symbol in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F');

   function Hex_Value (Symbol : Character) return Unsigned_16 is
     (case Symbol is
         when '0' .. '9' => Character'Pos (Symbol) - Character'Pos ('0'),
         when 'a' .. 'f' => Character'Pos (Symbol) - Character'Pos ('a') + 10,
         when 'A' .. 'F' => Character'Pos (Symbol) - Character'Pos ('A') + 10,
         when others     => 0);

   --  Four decimal numbers 0 .. 255 joined by dots. A number with a leading zero ("010") is refused: some
   --  parsers read it as octal, and an address must mean the same thing to every program that reads it.
   procedure Parse_Quad (Text : String; Into : out Four_Bytes; Valid : out Boolean) is
      Part        : Natural := 0;
      Digits_Seen : Natural := 0;
      Index       : Positive := 1;
   begin
      Into  := [others => 0];
      Valid := False;
      for Symbol of Text loop
         pragma Loop_Invariant (Part <= 255 and then Digits_Seen <= 3 and then Index <= 4);
         if Symbol in '0' .. '9' then
            if Digits_Seen = 3 or else (Digits_Seen > 0 and then Part = 0) then
               return;
            end if;
            Part := Part * 10 + (Character'Pos (Symbol) - Character'Pos ('0'));
            if Part > 255 then
               return;
            end if;
            Digits_Seen := Digits_Seen + 1;
         elsif Symbol = '.' and then Digits_Seen > 0 and then Index < 4 then
            Into (Index) := Unsigned_8 (Part);
            Index        := Index + 1;
            Part         := 0;
            Digits_Seen  := 0;
         else
            return;
         end if;
      end loop;

      if Index = 4 and then Digits_Seen > 0 then
         Into (4) := Unsigned_8 (Part);
         Valid    := True;
      end if;
   end Parse_Quad;

   --  Eight groups of one to four hex digits joined by colons; "::" once in place of one or more zero groups;
   --  the last two groups may be written as a dotted quad.
   procedure Parse_Six (Text : String; Into : out Sixteen_Bytes; Valid : out Boolean)
      with Pre => Text'Last < Positive'Last
   is
      Groups  : Group_Array := [others => 0];
      Count   : Natural := 0;
      Has_Gap : Boolean := False;
      Gap_At  : Natural := 0;   --  how many groups come before the "::"
      Next    : Positive;
   begin
      Into  := [others => 0];
      Valid := False;
      if Text'Length < 2 then
         return;
      end if;
      Next := Text'First;
      if Text (Text'First) = ':' then
         if Text (Text'First + 1) /= ':' then
            return;
         end if;
         Has_Gap := True;
         Next    := Text'First + 2;
      end if;

      while Next <= Text'Last loop
         pragma Loop_Invariant (Count <= 8 and then Gap_At <= Count and then Next >= Text'First);
         pragma Loop_Variant (Increases => Next);
         declare
            Stop : Positive := Next;   --  one past the group
         begin
            while Stop <= Text'Last and then Text (Stop) /= ':' loop
               pragma Loop_Invariant (Stop in Next .. Text'Last);
               Stop := Stop + 1;
            end loop;
            if Stop = Next then
               return;
            end if;

            if (for some Index in Next .. Stop - 1 => Text (Index) = '.') then
               --  A dotted quad: only as the last two groups.
               if Stop <= Text'Last or else Count > 6 then
                  return;
               end if;
               declare
                  Quad : Four_Bytes;
                  Good : Boolean;
               begin
                  Parse_Quad (Text (Next .. Stop - 1), Quad, Good);
                  if not Good then
                     return;
                  end if;
                  Groups (Count + 1) := Unsigned_16 (Quad (1)) * 256 + Unsigned_16 (Quad (2));
                  Groups (Count + 2) := Unsigned_16 (Quad (3)) * 256 + Unsigned_16 (Quad (4));
                  Count := Count + 2;
               end;
               exit;
            end if;

            if Stop - Next > 4 or else Count = 8 then
               return;
            end if;
            declare
               Value : Unsigned_16 := 0;
            begin
               for Index in Next .. Stop - 1 loop
                  if not Is_Hex (Text (Index)) then
                     return;
                  end if;
                  Value := Value * 16 + Hex_Value (Text (Index));
               end loop;
               Count          := Count + 1;
               Groups (Count) := Value;
            end;

            exit when Stop > Text'Last;
            if Stop < Text'Last and then Text (Stop + 1) = ':' then
               if Has_Gap then
                  return;
               end if;
               Has_Gap := True;
               Gap_At  := Count;
               Next    := Stop + 2;
            elsif Stop = Text'Last then
               return;   --  a colon at the end
            else
               Next := Stop + 1;
            end if;
         end;
      end loop;

      if (Has_Gap and then Count > 7) or else (not Has_Gap and then Count /= 8) then
         return;
      end if;

      --  The groups after the gap go to the end.
      for Index in 1 .. Count loop
         pragma Loop_Invariant (Count <= 8 and then Gap_At <= Count);
         declare
            Slot : constant Positive := (if Index <= Gap_At then Index else Index + 8 - Count);
         begin
            Into (2 * Slot - 1) := Unsigned_8 (Shift_Right (Groups (Index), 8));
            Into (2 * Slot)     := Unsigned_8 (Groups (Index) and 255);
         end;
      end loop;
      Valid := True;
   end Parse_Six;

   procedure Parse_Address (Text : String; Address : out IP_Address; Valid : out Boolean) is
      Raw  : Sixteen_Bytes;
      Quad : Four_Bytes;
   begin
      Address := Any_IPv4;
      Valid   := False;
      if Text'Length = 0 or else Text'Last = Positive'Last then
         return;
      end if;

      if Text (Text'First) = '[' then
         if Text'Length < 4 or else Text (Text'Last) /= ']' then
            return;
         end if;
         Parse_Six (Text (Text'First + 1 .. Text'Last - 1), Raw, Valid);
         Address := (Family => Version_6, Raw => Raw);
      elsif (for some Symbol of Text => Symbol = ':') then
         Parse_Six (Text, Raw, Valid);
         Address := (Family => Version_6, Raw => Raw);
      else
         Parse_Quad (Text, Quad, Valid);
         Address := From_Bytes (Quad);
      end if;

      if not Valid then
         Address := Any_IPv4;
      end if;
   end Parse_Address;

   ---------------------------------------------------------------------------------------------------------------
   --  writing

   Hex_Digits : constant String (1 .. 16) := "0123456789abcdef";

   --  A group in hex without leading zeros.
   function Group_Image (Value : Unsigned_16) return String
      with Post => Group_Image'Result'First = 1 and then Group_Image'Result'Length in 1 .. 4
   is
      Result : String (1 .. 4) := "0000";
      Last   : Natural := 0;
   begin
      for Position in reverse 0 .. 3 loop   --  the hex digit's place, most significant first
         pragma Loop_Invariant (Last <= 3 - Position);
         declare
            Digit : constant Unsigned_16 := Shift_Right (Value, 4 * Position) and 15;
         begin
            if Last > 0 or else Digit /= 0 or else Position = 0 then
               Last          := Last + 1;
               Result (Last) := Hex_Digits (Natural (Digit) + 1);
            end if;
         end;
      end loop;
      return Result (1 .. Last);
   end Group_Image;

   function Decimal_Image (Value : Unsigned_8) return String
      with Post => Decimal_Image'Result'First = 1 and then Decimal_Image'Result'Length in 1 .. 3
   is
      Digit : constant array (Unsigned_8 range 0 .. 9) of Character := "0123456789";
   begin
      if Value >= 100 then
         return [Digit (Value / 100), Digit (Value / 10 mod 10), Digit (Value mod 10)];
      elsif Value >= 10 then
         return [Digit (Value / 10), Digit (Value mod 10)];
      else
         return [1 => Digit (Value)];
      end if;
   end Decimal_Image;

   function Quad_Image (Raw : Four_Bytes) return String is
     (Decimal_Image (Raw (1)) & "." & Decimal_Image (Raw (2)) & "." & Decimal_Image (Raw (3)) & "."
      & Decimal_Image (Raw (4)))
      with Post => Quad_Image'Result'Length in 7 .. 15;

   --  Eight groups in the RFC 5952 form.
   function Six_Image (Groups : Group_Array) return String
      with Post => Six_Image'Result'First = 1 and then Six_Image'Result'Length <= 39
   is
      Best_Start     : Positive := 1;
      Best_Length    : Natural := 0;
      Current_Start  : Positive := 1;
      Current_Length : Natural := 0;
      Result         : String (1 .. 39) := [others => ' '];
      Last           : Natural := 0;
      Index          : Positive := 1;

      procedure Put (Part : String)
         with Pre  => Part'Length <= 39 - Last,
              Post => Last = Last'Old + Part'Length
      is begin
         Result (Last + 1 .. Last + Part'Length) := Part;
         Last := Last + Part'Length;
      end Put;
   begin
      --  The longest run of zero groups (the first, when two are as long) is written "::", if it is at
      --  least two groups long (RFC 5952, 4.2).
      for Group in Groups'Range loop
         pragma Loop_Invariant
           (Current_Length <= Group - 1 and then Current_Start + Current_Length = Group
            and then Best_Length <= Group - 1 and then Best_Start + Best_Length <= Group);
         if Groups (Group) = 0 then
            Current_Length := Current_Length + 1;
            if Current_Length > Best_Length then
               Best_Start  := Current_Start;
               Best_Length := Current_Length;
            end if;
         else
            Current_Start  := Group + 1;
            Current_Length := 0;
         end if;
      end loop;
      if Best_Length < 2 then
         Best_Length := 0;
      end if;

      while Index <= 8 loop
         pragma Loop_Invariant ((if Index = 1 then Last = 0 else Last + 1 <= 5 * (Index - 1)));
         pragma Loop_Variant (Increases => Index);
         if Best_Length > 0 and then Index = Best_Start then
            Put ("::");
            Index := Index + Best_Length;
         else
            if Index > 1 and then not (Best_Length > 0 and then Index = Best_Start + Best_Length) then
               Put (":");
            end if;
            Put (Group_Image (Groups (Index)));
            Index := Index + 1;
         end if;
      end loop;
      return Result (1 .. Last);
   end Six_Image;

   function Image (Address : IP_Address) return String is
   begin
      if Address.Family = Version_4 then
         declare
            Text : constant String := Quad_Image (Address.Raw (1 .. 4));
         begin
            return Result : constant String (1 .. Text'Length) := Text;
         end;
      elsif Is_Mapped (Address) then
         declare
            Text : constant String := "::ffff:" & Quad_Image (Address.Raw (13 .. 16));
         begin
            return Result : constant String (1 .. Text'Length) := Text;
         end;
      end if;

      return Six_Image
        ([for Group in Group_Array'Range =>
            Unsigned_16 (Address.Raw (2 * Group - 1)) * 256 + Unsigned_16 (Address.Raw (2 * Group))]);
   end Image;

end Sparrow.IO.Addresses;
