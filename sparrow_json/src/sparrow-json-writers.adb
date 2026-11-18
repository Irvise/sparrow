with Ada.Text_IO;
with Sparrow.Encoding;

package body Sparrow.Json.Writers with SPARK_Mode is

   Hex_Digits : constant String (1 .. 16) := "0123456789abcdef";

   -------------------
   -- Append_String --
   -------------------

   procedure Append_String (To : in out Buffer; Text : UTF8_String) is
      Start : Integer := Text'First;   --  of the run of characters that need no escape

      procedure Flush (Before : Integer)
         with Pre  => Valid (To) and then Text'Length <= 2 ** 26 and then Start >= Text'First
                      and then Start <= Before and then Before - 1 <= Text'Last,
              Post => Valid (To) and then To.Length >= To.Length'Old
                      and then To.Length <= To.Length'Old + (Before - Start)
      is begin
         if Before > Start then
            Append (To, String (Text (Start .. Before - 1)));
         end if;
      end Flush;
   begin
      if Text'Length = 0 then   --  (its bounds may be anything, such as 5 .. 2)
         Append (To, '"');
         Append (To, '"');
         return;
      end if;
      Reserve (To, Natural'Min (Text'Length, Max_Capacity - 2) + 2);
      Append (To, '"');

      for Index in Text'Range loop
         pragma Loop_Invariant (Valid (To) and then To.Length >= To.Length'Loop_Entry
                                and then Start in Text'First .. Index
                                and then To.Length - To.Length'Loop_Entry <= 6 * (Start - Text'First));
         declare
            Symbol : constant Character := Text (Index);
         begin
            if Symbol in '"' | '\' | ASCII.NUL .. ASCII.US then
               Flush (Index);
               Start := Index + 1;
               case Symbol is
                  when '"'      => Append (To, "\""");
                  when '\'      => Append (To, "\\");
                  when ASCII.LF => Append (To, "\n");
                  when ASCII.CR => Append (To, "\r");
                  when ASCII.HT => Append (To, "\t");
                  when others   =>
                     Append (To, "\u00");
                     Append (To, Hex_Digits (Character'Pos (Symbol) / 16 + 1));
                     Append (To, Hex_Digits (Character'Pos (Symbol) mod 16 + 1));
               end case;
            end if;
         end;
      end loop;

      Flush (Text'Last + 1);
      Append (To, '"');
   end Append_String;

   -----------------
   -- Begin_Value --
   -----------------

   --  What comes before any value: nothing after a key or at the top, a comma between the items of an array.
   --  Fits is False where a value cannot go: after the top-level value is done, or in an object without a key.
   procedure Begin_Value (This : in out Writer; Into : in out Buffer; Fits : out Boolean)
      with Pre => Valid (Into), Post => Valid (Into) and then This.Current = This.Current'Old
   is begin
      Fits := False;
      if not This.Sound or else This.Done then
         This.Sound := False;
      elsif This.Current = 0 then
         Fits := True;
      else
         declare
            Top : constant Depth := This.Current;   --  (SPARK: no renaming at a variable index)
         begin
            if This.Levels (Top).In_Object then
               if This.Levels (Top).After_Key then
                  This.Levels (Top).After_Key := False;
                  Fits                        := True;
               else
                  This.Sound := False;
               end if;
            else
               if This.Levels (Top).Has_Items then
                  Append (Into, ',');
               end if;
               This.Levels (Top).Has_Items := True;
               Fits                        := True;
            end if;
         end;
      end if;
   end Begin_Value;

   ---------------
   -- End_Value --
   ---------------

   --  A value at the top level is the whole document.
   procedure End_Value (This : in out Writer) is begin
      if This.Current = 0 then
         This.Done := True;
      end if;
   end End_Value;

   ----------
   -- Open --
   ----------

   procedure Open (This : in out Writer; Into : in out Buffer; Bracket : Character; In_Object : Boolean)
      with Pre => Valid (Into), Post => Valid (Into)
   is
      Fits : Boolean;
   begin
      if This.Current = Depth'Last then
         This.Sound := False;
         return;
      end if;

      Begin_Value (This, Into, Fits);
      if Fits then
         Append (Into, Bracket);
         This.Current               := This.Current + 1;
         This.Levels (This.Current) := (In_Object => In_Object, Has_Items => False, After_Key => False);
      end if;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (This : in out Writer; Into : in out Buffer; Bracket : Character; In_Object : Boolean)
      with Pre => Valid (Into), Post => Valid (Into)
   is begin
      if not This.Sound
        or else This.Current = 0
        or else This.Levels (This.Current).In_Object /= In_Object
        or else This.Levels (This.Current).After_Key
      then
         This.Sound := False;
         return;
      end if;

      Append (Into, Bracket);
      This.Current := This.Current - 1;
      End_Value (This);
   end Close;

   procedure Begin_Object (This : in out Writer; Into : in out Buffer) is begin
      Open (This, Into, '{', In_Object => True);
   end Begin_Object;

   procedure End_Object (This : in out Writer; Into : in out Buffer) is begin
      Close (This, Into, '}', In_Object => True);
   end End_Object;

   procedure Begin_Array (This : in out Writer; Into : in out Buffer) is begin
      Open (This, Into, '[', In_Object => False);
   end Begin_Array;

   procedure End_Array (This : in out Writer; Into : in out Buffer) is begin
      Close (This, Into, ']', In_Object => False);
   end End_Array;

   ---------
   -- Key --
   ---------

   procedure Key (This : in out Writer; Into : in out Buffer; Name : UTF8_String) is begin
      if not This.Sound
        or else This.Current = 0
        or else not This.Levels (This.Current).In_Object
        or else This.Levels (This.Current).After_Key
        or else Name'Length > 2 ** 26 or else Name'Last = Integer'Last   --  past what a document sensibly holds
      then
         This.Sound := False;
         return;
      end if;

      if This.Levels (This.Current).Has_Items then
         Append (Into, ',');
      end if;
      This.Levels (This.Current).Has_Items := True;
      This.Levels (This.Current).After_Key := True;
      Append_String (Into, Name);
      Append (Into, ':');
   end Key;

   -----------
   -- Value --
   -----------

   procedure Value (This : in out Writer; Into : in out Buffer; Text : UTF8_String) is
      Fits : Boolean;
   begin
      Begin_Value (This, Into, Fits);
      if Fits and then (Text'Length > 2 ** 26 or else Text'Last = Integer'Last) then
         This.Sound := False;   --  past what a document here can sensibly hold
      elsif Fits then
         Append_String (Into, Text);
         End_Value (This);
      end if;
   end Value;

   procedure Value (This : in out Writer; Into : in out Buffer; Number : Long_Long_Integer) is
      Fits : Boolean;
   begin
      Begin_Value (This, Into, Fits);
      if Fits then
         Append_Integer (Into, Number);
         End_Value (This);
      end if;
   end Value;

   --  The shortest of 15, 16 or 17 significant digits that reads back as Number, in JSON's number syntax.
   --  Outside SPARK: text conversions of a floating-point type.
   function Float_Image (Number : Long_Float) return String
      with Post => Float_Image'Result'Length <= 64;

   function Float_Image (Number : Long_Float) return String with SPARK_Mode => Off is
      package Float_Text is new Ada.Text_IO.Float_IO (Long_Float);

      --  "  -d.dddE+nn" the way JavaScript writes numbers: plain decimals for exponents from -6 to 20,
      --  otherwise d.ddde[-]nn; no trailing zeros.
      function As_Json (Image : String) return String is
         E        : Natural := Image'First;
         First    : Natural := Image'First;
         Stop     : Natural;
         Exponent : Integer;
      begin
         while Image (First) = ' ' loop
            First := First + 1;
         end loop;
         while Image (E) /= 'E' loop
            E := E + 1;
         end loop;
         Exponent := Integer'Value (Image (E + 1 .. Image'Last));

         Stop := E - 1;
         while Image (Stop) = '0' loop
            Stop := Stop - 1;
         end loop;

         declare
            Sign   : constant String := (if Image (First) = '-' then "-" else "");
            Start  : constant Natural := First + Sign'Length;                   --  the digit before the point
            Rest   : constant String := Image (Start + 2 .. Stop);              --  the digits after it
            Figures : constant String := Image (Start) & Rest;
         begin
            if Exponent in 0 .. 20 then
               if Rest'Length <= Exponent then
                  return Sign & Figures & [1 .. Exponent - Rest'Length => '0'];
               else
                  return Sign & Figures (Figures'First .. Figures'First + Exponent) & "."
                    & Figures (Figures'First + Exponent + 1 .. Figures'Last);
               end if;
            elsif Exponent in -6 .. -1 then
               return Sign & "0." & [1 .. -Exponent - 1 => '0'] & Figures;
            else
               return Sign & Image (Start) & (if Rest'Length > 0 then "." & Rest else "")
                 & "e" & Sparrow.Encoding.Decimal_Image (Long_Long_Integer (Exponent));
            end if;
         end;
      end As_Json;
   begin
      if Number = Long_Float'Truncation (Number) and then abs Number < 1.0E15 then
         return Sparrow.Encoding.Decimal_Image (Long_Long_Integer (Number));
      end if;

      for Fraction_Digits in 14 .. 16 loop
         declare
            Image : String (1 .. 32);
         begin
            Float_Text.Put (Image, Number, Aft => Fraction_Digits, Exp => 4);
            if Fraction_Digits = 16 or else Long_Float'Value (Image) = Number then
               return As_Json (Image);
            end if;
         end;
      end loop;

      return "0";   --  not reached
   end Float_Image;

   function Is_Finite (Number : Long_Float) return Boolean;
   function Is_Finite (Number : Long_Float) return Boolean is (Number'Valid) with SPARK_Mode => Off;

   procedure Value (This : in out Writer; Into : in out Buffer; Number : Long_Float) is
      Fits : Boolean;
   begin
      Begin_Value (This, Into, Fits);
      if Fits then
         if Is_Finite (Number) then
            Append (Into, Float_Image (Number));
         else
            Append (Into, "null");
         end if;
         End_Value (This);
      end if;
   end Value;

   procedure Value (This : in out Writer; Into : in out Buffer; Flag : Boolean) is
      Fits : Boolean;
   begin
      Begin_Value (This, Into, Fits);
      if Fits then
         Append (Into, (if Flag then "true" else "false"));
         End_Value (This);
      end if;
   end Value;

   ----------------
   -- Null_Value --
   ----------------

   procedure Null_Value (This : in out Writer; Into : in out Buffer) is
      Fits : Boolean;
   begin
      Begin_Value (This, Into, Fits);
      if Fits then
         Append (Into, "null");
         End_Value (This);
      end if;
   end Null_Value;

   ---------------
   -- Raw_Value --
   ---------------

   procedure Raw_Value (This : in out Writer; Into : in out Buffer; Fragment : UTF8_String) is
      Fits : Boolean;
   begin
      Begin_Value (This, Into, Fits);
      if Fits then
         Append_Text (Into, Fragment);
         End_Value (This);
      end if;
   end Raw_Value;

   ------------
   -- Member --
   ------------

   procedure Member (This : in out Writer; Into : in out Buffer; Name : UTF8_String; Text : UTF8_String) is begin
      Key (This, Into, Name);
      Value (This, Into, Text);
   end Member;

   procedure Member (This : in out Writer; Into : in out Buffer; Name : UTF8_String; Number : Long_Long_Integer) is
   begin
      Key (This, Into, Name);
      Value (This, Into, Number);
   end Member;

   procedure Member (This : in out Writer; Into : in out Buffer; Name : UTF8_String; Flag : Boolean) is begin
      Key (This, Into, Name);
      Value (This, Into, Flag);
   end Member;

end Sparrow.Json.Writers;
