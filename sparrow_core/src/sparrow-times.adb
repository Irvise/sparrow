package body Sparrow.Times with SPARK_Mode is

   subtype Wide is Long_Long_Integer;

   function Digit (Value : Wide) return Character is (Character'Val (Character'Pos ('0') + Natural (Value)))
      with Pre => Value in 0 .. 9;

   --  Floor division: Ada's "/" rounds toward zero.
   function Floor_Divide (Left : Wide; Right : Wide) return Wide is
     (if Left >= 0 then Left / Right else -((-(Left + 1)) / Right) - 1)
      with Pre => Right > 0;

   type Civil_Date is record
      Year  : Wide;
      Month : Wide range 1 .. 12;
      Day   : Wide range 1 .. 31;
   end record;

   --  civil_from_days (Howard Hinnant's algorithm), for days since 1970-01-01.
   function To_Civil (Day : Wide) return Civil_Date
      with Pre => Day in -(10 ** 14) .. 10 ** 14
   is
      Shifted      : constant Wide := Day + 719_468;
      Era          : constant Wide := Floor_Divide (Shifted, 146_097);
      Day_Of_Era   : constant Wide range 0 .. 146_096 := Shifted - Era * 146_097;
      Year_Of_Era  : constant Wide range 0 .. 399 :=
        (Day_Of_Era - Day_Of_Era / 1460 + Day_Of_Era / 36_524 - Day_Of_Era / 146_096) / 365;
      Day_Of_Year  : constant Wide := Day_Of_Era - (365 * Year_Of_Era + Year_Of_Era / 4 - Year_Of_Era / 100);
      March_Month  : constant Wide := (5 * Day_Of_Year + 2) / 153;   --  0 = March
      Day_Of_Month : constant Wide := Day_Of_Year - (153 * March_Month + 2) / 5 + 1;
      Month        : constant Wide := (if March_Month < 10 then March_Month + 3 else March_Month - 9);
   begin
      --  The algorithm keeps these in range; the clamps spare the proof from knowing it.
      return (Year  => Year_Of_Era + Era * 400 + (if Month <= 2 then 1 else 0),
              Month => Wide'Max (1, Wide'Min (12, Month)),
              Day   => Wide'Max (1, Wide'Min (31, Day_Of_Month)));
   end To_Civil;

   --  days_from_civil, the reverse.
   function From_Civil (Year : Wide; Month : Wide; Day : Wide) return Wide
      with Pre  => Year in 0 .. 9999 and then Month in 1 .. 12 and then Day in 1 .. 31,
           Post => From_Civil'Result in -800_000 .. 3_000_000   --  years 0 to 9999
   is
      Shifted_Year : constant Wide := (if Month <= 2 then Year - 1 else Year);
      Era          : constant Wide := Floor_Divide (Shifted_Year, 400);
      Year_Of_Era  : constant Wide := Shifted_Year - Era * 400;
      Day_Of_Year  : constant Wide := (153 * (if Month > 2 then Month - 3 else Month + 9) + 2) / 5 + Day - 1;
      Day_Of_Era   : constant Wide := Year_Of_Era * 365 + Year_Of_Era / 4 - Year_Of_Era / 100 + Day_Of_Year;
   begin
      return Era * 146_097 + Day_Of_Era - 719_468;
   end From_Civil;

   function Days_In (Year : Wide; Month : Wide) return Wide is
     (case Month is
         when 4 | 6 | 9 | 11 => 30,
         when 2              => (if Year mod 4 = 0 and then (Year mod 100 /= 0 or else Year mod 400 = 0)
                                 then 29 else 28),
         when others         => 31)
      with Pre => Month in 1 .. 12;

   --  A time this unit formats as it is; anything outside is clamped to it first.
   Limit : constant := 10 ** 17;   --  seconds: far beyond year 9999 either way

   ----------------
   -- To_Seconds --
   ----------------

   function To_Seconds (Time : Unix_Microseconds) return Unix_Seconds is
     (Unix_Seconds (Floor_Divide (Wide (Time), 1_000_000)));

   ---------------------
   -- To_Microseconds --
   ---------------------

   function To_Microseconds (Time : Unix_Seconds) return Unix_Microseconds is
     (Unix_Microseconds (Wide (Time) * 1_000_000));

   --  The last Width decimal digits of Value (its magnitude) into Text at First.
   procedure Put (Text : in out String; First : Positive; Width : Positive; Value : Wide)
      with Pre => Width <= 4 and then First in Text'Range and then Text'Last - First >= Width - 1
   is
      Remaining : Wide := Value;
   begin
      for Offset in reverse 0 .. Width - 1 loop
         Text (First + Offset) := Digit (abs (Remaining rem 10));
         Remaining       := Remaining / 10;
      end loop;
   end Put;

   -------------
   -- Rfc3339 --
   -------------

   function Rfc3339 (Time : Unix_Microseconds) return Rfc3339_Text is
      Total_Ms : constant Wide := Floor_Divide (Wide (Time), 1000);
      Day      : constant Wide := Floor_Divide (Total_Ms, 86_400_000);
      Of_Day   : constant Wide := Total_Ms - Day * 86_400_000;
      Date     : constant Civil_Date := To_Civil (Wide'Max (-(10 ** 14), Wide'Min (10 ** 14, Day)));
      Text     : Rfc3339_Text := "0000-00-00T00:00:00.000Z";
   begin
      Put (Text, 1, 4, Date.Year);
      Put (Text, 6, 2, Date.Month);
      Put (Text, 9, 2, Date.Day);
      Put (Text, 12, 2, Of_Day / 3_600_000);
      Put (Text, 15, 2, Of_Day / 60_000 mod 60);
      Put (Text, 18, 2, Of_Day / 1000 mod 60);
      Put (Text, 21, 3, Of_Day mod 1000);
      return Text;
   end Rfc3339;

   ---------------
   -- Http_Date --
   ---------------

   function Http_Date (Time : Unix_Seconds) return Http_Date_Text is
      Day_Names   : constant String := "ThuFriSatSunMonTueWed";   --  1970-01-01 was a Thursday
      Month_Names : constant String := "JanFebMarAprMayJunJulAugSepOctNovDec";

      Clamped : constant Wide := Wide'Max (-Limit, Wide'Min (Limit, Wide (Time)));
      Day     : constant Wide := Floor_Divide (Clamped, 86_400);
      Of_Day  : constant Wide := Clamped - Day * 86_400;
      Date    : constant Civil_Date := To_Civil (Day);
      Weekday : constant Natural := Natural (Day - Floor_Divide (Day, 7) * 7);
      Month   : constant Natural := Natural (Date.Month);
      Text    : Http_Date_Text := "Thu, 01 Jan 1970 00:00:00 GMT";
   begin
      Text (1 .. 3)  := Day_Names (Weekday * 3 + 1 .. Weekday * 3 + 3);
      Put (Text, 6, 2, Date.Day);
      Text (9 .. 11) := Month_Names (Month * 3 - 2 .. Month * 3);
      Put (Text, 13, 4, Date.Year);
      Put (Text, 18, 2, Of_Day / 3600);
      Put (Text, 21, 2, Of_Day / 60 mod 60);
      Put (Text, 24, 2, Of_Day mod 60);
      return Text;
   end Http_Date;

   -------------------
   -- Parse_Rfc3339 --
   -------------------

   procedure Parse_Rfc3339 (Source : String; Time : out Unix_Microseconds; Valid : out Boolean) is
      Next : Integer := Source'First;
      Bad  : Boolean := False;

      --  Exactly Width digits at Next.
      procedure Number (Width : Positive; Value : out Wide)
         with Pre  => Width <= 4 and then Source'Last < Integer'Last and then Next >= Source'First
                      and then Next - 1 <= Source'Last,
              Post => Next >= Next'Old and then Next - 1 <= Source'Last and then Value in 0 .. 9999
      is begin
         Value := 0;
         for Count in 1 .. Width loop
            pragma Loop_Invariant
              (Next >= Next'Loop_Entry and then Next - 1 <= Source'Last
               and then Value in 0 .. (case Count is when 1 => 0, when 2 => 9, when 3 => 99, when others => 999));
            if Next > Source'Last or else Source (Next) not in '0' .. '9' then
               Bad := True;
               return;
            end if;
            Value := Value * 10 + (Character'Pos (Source (Next)) - Character'Pos ('0'));
            Next  := Next + 1;
         end loop;
      end Number;

      procedure Expect (Symbols : String)
         with Pre  => Source'Last < Integer'Last and then Next >= Source'First and then Next - 1 <= Source'Last,
              Post => Next >= Next'Old and then Next - 1 <= Source'Last
      is begin
         if Next > Source'Last or else (for all Symbol of Symbols => Symbol /= Source (Next)) then
            Bad := True;
         else
            Next := Next + 1;
         end if;
      end Expect;

      Year, Month, Day, Hour, Minute, Second : Wide;
      Micros        : Wide := 0;
      Scale         : Wide := 100_000;
      Offset        : Wide range -1439 .. 1439 := 0;   --  minutes east of UTC
      Offset_Hour   : Wide;
      Offset_Minute : Wide;
      West          : Boolean;
   begin
      Time  := 0;
      Valid := False;
      if Source'Length not in 20 .. 40 or else Source'Last = Integer'Last then
         return;
      end if;

      Number (4, Year);   Expect ("-");
      Number (2, Month);  Expect ("-");
      Number (2, Day);    Expect ("Tt ");
      Number (2, Hour);   Expect (":");
      Number (2, Minute); Expect (":");
      Number (2, Second);
      if Bad then
         return;
      end if;

      if Next <= Source'Last and then Source (Next) = '.' then
         Next := Next + 1;
         if Next > Source'Last or else Source (Next) not in '0' .. '9' then
            return;
         end if;
         while Next <= Source'Last and then Source (Next) in '0' .. '9' loop
            pragma Loop_Invariant (Next >= Source'First and then Next < Source'Last + 1
                                   and then Micros in 0 .. 999_999 and then Scale in 0 .. 100_000
                                   and then Micros + Scale * 10 <= 1_000_000);
            pragma Loop_Variant (Increases => Next);
            Micros := Micros + Scale * (Character'Pos (Source (Next)) - Character'Pos ('0'));
            Scale  := Scale / 10;   --  digits past the sixth are dropped
            Next   := Next + 1;
         end loop;
      end if;

      if Next > Source'Last then
         return;
      elsif Source (Next) in 'Z' | 'z' then
         Next := Next + 1;
      elsif Source (Next) in '+' | '-' then
         West := Source (Next) = '-';
         Next := Next + 1;
         Number (2, Offset_Hour); Expect (":");
         Number (2, Offset_Minute);
         if Bad or else Offset_Hour > 23 or else Offset_Minute > 59 then
            return;
         end if;
         Offset := (if West then -(Offset_Hour * 60 + Offset_Minute) else Offset_Hour * 60 + Offset_Minute);
      else
         return;
      end if;

      if Next /= Source'Last + 1
        or else Month not in 1 .. 12
        or else Day not in 1 .. 31
        or else Day > Days_In (Year, Month)
        or else Hour > 23
        or else Minute > 59
        or else Second > 60   --  a leap second reads as the next second
      then
         return;
      end if;

      Time  := Unix_Microseconds
        ((From_Civil (Year, Month, Day) * 86_400 + Hour * 3600 + Minute * 60 + Second - Offset * 60) * 1_000_000
         + Micros);
      Valid := True;
   end Parse_Rfc3339;

end Sparrow.Times;
