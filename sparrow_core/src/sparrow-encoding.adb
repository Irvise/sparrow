with Interfaces; use Interfaces;

package body Sparrow.Encoding with SPARK_Mode is

   -----------
   -- Slice --
   -----------

   function Slice (Source : String; Item : Span) return String is
     (if Length (Item) = 0 then "" else Source (Item.First .. Item.Last));

   ----------------
   -- Valid_Utf8 --
   ----------------

   function Valid_Utf8 (Source : String) return Boolean is
      Next : Natural := 0;   --  offset of the next sequence

      function Byte (Offset : Natural) return Natural is (Character'Pos (Source (Source'First + Offset)))
         with Pre => Offset < Source'Length;

      --  Whether the byte at Offset exists and is a continuation byte (10xxxxxx).
      function Continues (Offset : Natural) return Boolean is
        (Offset < Source'Length and then Byte (Offset) in 16#80# .. 16#BF#);
   begin
      while Next < Source'Length loop
         pragma Loop_Invariant (Next < Source'Length);
         pragma Loop_Variant (Increases => Next);

         declare
            Lead : constant Natural := Byte (Next);
         begin
            case Lead is
               when 16#00# .. 16#7F# =>
                  Next := Next + 1;
               when 16#C2# .. 16#DF# =>
                  if not Continues (Next + 1) then
                     return False;
                  end if;
                  Next := Next + 2;
               when 16#E0# .. 16#EF# =>
                  if not (Continues (Next + 1) and then Continues (Next + 2))
                    or else (Lead = 16#E0# and then Byte (Next + 1) < 16#A0#)   --  overlong
                    or else (Lead = 16#ED# and then Byte (Next + 1) > 16#9F#)   --  surrogate
                  then
                     return False;
                  end if;
                  Next := Next + 3;
               when 16#F0# .. 16#F4# =>
                  if not (Continues (Next + 1) and then Continues (Next + 2) and then Continues (Next + 3))
                    or else (Lead = 16#F0# and then Byte (Next + 1) < 16#90#)   --  overlong
                    or else (Lead = 16#F4# and then Byte (Next + 1) > 16#8F#)   --  above U+10FFFF
                  then
                     return False;
                  end if;
                  Next := Next + 4;
               when others =>
                  return False;
            end case;
         end;
      end loop;

      return True;
   end Valid_Utf8;

   -------------
   -- To_UTF8 --
   -------------

   --  The bare conversion is sound here: the precondition is Valid_Utf8 (Source).
   function To_UTF8 (Source : String) return UTF8_String is (UTF8_String (Source));

   --------------
   -- To_Bytes --
   --------------

   function To_Bytes (Source : UTF8_String) return String is (String (Source));

   ------------------
   -- From_Unicode --
   ------------------

   function From_Unicode (Source : Wide_Wide_String) return UTF8_String is
      Result : String (1 .. 4 * Source'Length) := [others => ' '];
      Last   : Natural := 0;

      procedure Put (Code : Natural)
         with Pre => Code <= 255 and then Last < Result'Last, Post => Last = Last'Old + 1
      is begin
         Last          := Last + 1;
         Result (Last) := Character'Val (Code);
      end Put;
   begin
      for Index in Source'Range loop
         pragma Loop_Invariant (Last <= 4 * (Index - Source'First));
         declare
            Raw   : constant Natural := Wide_Wide_Character'Pos (Source (Index));
            Point : constant Natural :=
              (if Raw in 16#D800# .. 16#DFFF# or else Raw > 16#10_FFFF# then 16#FFFD# else Raw);
         begin
            case Point is
               when 0 .. 16#7F# =>
                  Put (Point);
               when 16#80# .. 16#7FF# =>
                  Put (16#C0# + Point / 64);
                  Put (16#80# + Point mod 64);
               when 16#800# .. 16#FFFF# =>
                  Put (16#E0# + Point / 4096);
                  Put (16#80# + Point / 64 mod 64);
                  Put (16#80# + Point mod 64);
               when others =>
                  Put (16#F0# + Point / 262_144);
                  Put (16#80# + Point / 4096 mod 64);
                  Put (16#80# + Point / 64 mod 64);
                  Put (16#80# + Point mod 64);
            end case;
         end;
      end loop;

      --  Sound: each code point was written as its well-formed UTF-8 sequence.
      return UTF8_String (Result (1 .. Last));
   end From_Unicode;

   --------------------
   -- Encode_Latin_1 --
   --------------------

   function Encode_Latin_1 (Source : String) return UTF8_String is
      Result : String (1 .. 2 * Source'Length) := [others => ' '];
      Last   : Natural := 0;
   begin
      for Index in Source'Range loop
         pragma Loop_Invariant (Last in Index - Source'First .. 2 * (Index - Source'First));
         declare
            Code : constant Natural := Character'Pos (Source (Index));
         begin
            if Code < 16#80# then
               Last          := Last + 1;
               Result (Last) := Source (Index);
            else
               Result (Last + 1) := Character'Val (16#C0# + Code / 64);
               Result (Last + 2) := Character'Val (16#80# + Code mod 64);
               Last              := Last + 2;
            end if;
         end;
      end loop;

      --  Sound: every character was written as ASCII or as a well-formed two-byte sequence.
      return UTF8_String (Result (1 .. Last));
   end Encode_Latin_1;

   --------------------
   -- Decode_Latin_1 --
   --------------------

   procedure Decode_Latin_1 (Source : UTF8_String; Into : out String; Last : out Natural; Valid : out Boolean) is
      Next : Integer := Source'First;
   begin
      Into  := [others => ' '];
      Last  := Into'First - 1;
      Valid := False;
      if Source'Last = Integer'Last then
         return;   --  no index past the end to step to; no real string ends there
      end if;

      while Next <= Source'Last loop
         pragma Loop_Invariant (Next >= Source'First and then (Last = Into'First - 1 or else Last in Into'Range));
         pragma Loop_Variant (Increases => Next);

         if Last >= Into'Last then
            return;
         end if;

         declare
            Lead : constant Natural := Character'Pos (Source (Next));
         begin
            if Lead < 16#80# then
               Last        := Last + 1;
               Into (Last) := Character'Val (Lead);
               Next        := Next + 1;
            elsif Lead in 16#C2# .. 16#C3#
              and then Next < Source'Last
              and then Character'Pos (Source (Next + 1)) in 16#80# .. 16#BF#
            then
               Last        := Last + 1;
               Into (Last) := Character'Val ((Lead - 16#C0#) * 64 + Character'Pos (Source (Next + 1)) - 16#80#);
               Next        := Next + 2;
            else
               return;   --  past U+00FF
            end if;
         end;
      end loop;

      Valid := True;
   end Decode_Latin_1;

   -------------------
   -- Decimal_Image --
   -------------------

   --  Item, indexed from 1.
   function From_One (Item : String) return String
      with Post => From_One'Result'First = 1 and then From_One'Result = Item
   is
      Result : constant String (1 .. Item'Length) := Item;
   begin
      return Result;
   end From_One;

   function Decimal_Image (Value : Long_Long_Integer) return String is
      Text      : String (1 .. 20) := [others => '0'];
      First     : Positive;
      Magnitude : Unsigned_64 := (if Value < 0 then Unsigned_64 (-(Value + 1)) + 1 else Unsigned_64 (Value));
   begin
      for Count in 1 .. 20 loop   --  2 ** 64 has 20 digits
         First        := Text'Last + 1 - Count;
         Text (First) := Character'Val (Character'Pos ('0') + Natural (Magnitude mod 10));
         Magnitude    := Magnitude / 10;
         exit when Magnitude = 0;
      end loop;

      if Value < 0 then
         if First = 1 then
            First := 2;   --  unreachable: a negative 64-bit value has at most 19 digits
         end if;
         First        := First - 1;
         Text (First) := '-';
      end if;

      return From_One (Text (First .. Text'Last));
   end Decimal_Image;

   -------------------
   -- Parse_Decimal --
   -------------------

   procedure Parse_Decimal (Source : String; Value : out Long_Long_Integer; Valid : out Boolean) is
      Negative  : constant Boolean := Source'Length > 1 and then Source (Source'First) = '-';
      First     : constant Integer := (if Negative then Source'First + 1 else Source'First);
      Limit     : constant Unsigned_64 := (if Negative then 2 ** 63 else 2 ** 63 - 1);
      Magnitude : Unsigned_64 := 0;
   begin
      Value := 0;
      Valid := False;
      if First > Source'Last then
         return;
      end if;

      for Index in First .. Source'Last loop
         pragma Loop_Invariant (Magnitude <= Limit);
         if Source (Index) not in '0' .. '9' then
            return;
         end if;

         declare
            Digit : constant Unsigned_64 := Character'Pos (Source (Index)) - Character'Pos ('0');
         begin
            if Magnitude > (Limit - Digit) / 10 then
               return;   --  overflow
            end if;
            Magnitude := Magnitude * 10 + Digit;
         end;
      end loop;

      if Negative then
         Value := (if Magnitude = 2 ** 63 then Long_Long_Integer'First else -Long_Long_Integer (Magnitude));
      else
         Value := Long_Long_Integer (Magnitude);
      end if;
      Valid := True;
   end Parse_Decimal;

   -------------------------
   -- Equal_Ignoring_Case --
   -------------------------

   function Equal_Ignoring_Case (Left, Right : String) return Boolean is

      function Lower (Symbol : Character) return Character is
        (if Symbol in 'A' .. 'Z' then Character'Val (Character'Pos (Symbol) + 32) else Symbol);
   begin
      if Left'Length /= Right'Length then
         return False;
      end if;

      for Offset in 0 .. Left'Length - 1 loop
         if Lower (Left (Left'First + Offset)) /= Lower (Right (Right'First + Offset)) then
            return False;
         end if;
      end loop;

      return True;
   end Equal_Ignoring_Case;

   --------------------
   -- Percent_Decode --
   --------------------

   procedure Percent_Decode
     (Source        : String;
      Into          : out String;
      Last          : out Natural;
      Valid         : out Boolean;
      Plus_Is_Space : Boolean := False)
   is
      Next : Integer := Source'First;

      function Hex (Symbol : Character) return Integer is
        (case Symbol is
            when '0' .. '9' => Character'Pos (Symbol) - Character'Pos ('0'),
            when 'a' .. 'f' => Character'Pos (Symbol) - Character'Pos ('a') + 10,
            when 'A' .. 'F' => Character'Pos (Symbol) - Character'Pos ('A') + 10,
            when others     => -1)
         with Post => Hex'Result in -1 .. 15;
   begin
      Into  := [others => ' '];
      Last  := Into'First - 1;
      Valid := False;
      if Source'Last = Integer'Last then
         return;   --  no index past the end to step to; no real string ends there
      end if;

      while Next <= Source'Last loop
         pragma Loop_Invariant (Next >= Source'First and then (Last = Into'First - 1 or else Last in Into'Range));
         pragma Loop_Variant (Increases => Next);

         if Last >= Into'Last then
            return;   --  Into is too short
         end if;

         Last := Last + 1;
         if Source (Next) = '%' then
            if Next > Source'Last - 2 or else Hex (Source (Next + 1)) < 0 or else Hex (Source (Next + 2)) < 0 then
               return;
            end if;
            Into (Last) := Character'Val (Hex (Source (Next + 1)) * 16 + Hex (Source (Next + 2)));
            Next        := Next + 3;
         else
            Into (Last) := (if Plus_Is_Space and then Source (Next) = '+' then ' ' else Source (Next));
            Next        := Next + 1;
         end if;
      end loop;

      Valid := True;
   end Percent_Decode;

   -----------------
   -- Query_Value --
   -----------------

   function Query_Value (Query : String; Name : String) return Span is
      Start : Integer := Query'First;   --  of the pair being looked at
   begin
      if Query'Last = Integer'Last then
         return Empty;
      end if;

      while Start <= Query'Last loop
         pragma Loop_Invariant (Start >= Query'First);
         pragma Loop_Variant (Increases => Start);

         declare
            Stop   : Integer := Start;   --  the '&' ending the pair, or one past the end
            Equals : Integer := 0;       --  the pair's first '=', 0 when it has none
         begin
            while Stop <= Query'Last and then Query (Stop) /= '&' loop
               pragma Loop_Invariant (Stop >= Start and then (Equals = 0 or else Equals in Start .. Stop - 1));
               pragma Loop_Variant (Increases => Stop);
               if Equals = 0 and then Query (Stop) = '=' then
                  Equals := Stop;
               end if;
               Stop := Stop + 1;
            end loop;
            pragma Assert (Stop <= Query'Last + 1);

            if Equals = 0 then
               if Stop > Start and then Query (Start .. Stop - 1) = Name then
                  return (First => Start, Last => Start - 1);   --  present, without a value
               end if;
            elsif Query (Start .. Equals - 1) = Name then
               return (First => Equals + 1, Last => Stop - 1);
            end if;

            exit when Stop > Query'Last;
            Start := Stop + 1;
         end;
      end loop;

      return Empty;
   end Query_Value;

end Sparrow.Encoding;
