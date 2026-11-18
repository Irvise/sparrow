package body Sparrow.Gzip with SPARK_Mode is

   type Crc_Table is array (Unsigned_8) of Unsigned_32;

   function Make_Table return Crc_Table is
      Result : Crc_Table;
   begin
      for Byte in Unsigned_8 loop
         declare
            Value : Unsigned_32 := Unsigned_32 (Byte);
         begin
            for Bit in 1 .. 8 loop
               Value := (if (Value and 1) = 1 then Shift_Right (Value, 1) xor 16#EDB8_8320#
                         else Shift_Right (Value, 1));
            end loop;
            Result (Byte) := Value;
         end;
      end loop;
      return Result;
   end Make_Table;

   Table : constant Crc_Table := Make_Table;

   function Crc_32 (Data : String; Previous : Unsigned_32 := 0) return Unsigned_32 is
      Value : Unsigned_32 := not Previous;
   begin
      for Item of Data loop
         Value := Table (Unsigned_8 (Value and 16#FF#) xor Unsigned_8 (Character'Pos (Item)))
                  xor Shift_Right (Value, 8);
      end loop;
      return not Value;
   end Crc_32;

   procedure Compress
     (Work    : in out Deflate.State;
      Input   : String;
      Output  : in out String;
      Last    : out Natural;
      Fits    : out Boolean;
      Padding : Natural := 0)
   is
      Head_Length : constant Natural := 10 + (if Padding > 0 then Padding + 1 else 0);
      Data_Last   : Natural;
   begin
      Last := Output'First - 1;
      Fits := False;
      if Output'Length < Head_Length + 8 then
         return;
      end if;
      declare
         Head : constant Positive := Output'First;
         Tail : constant Positive := Output'Last - 7;   --  where the trailer may start at the latest
      begin
         Output (Head .. Head + 9) :=
           Character'Val (16#1F#) & Character'Val (16#8B#) & Character'Val (8)
           & Character'Val (if Padding > 0 then 8 else 0)              --  FNAME when padded
           & Character'Val (0) & Character'Val (0) & Character'Val (0) & Character'Val (0)   --  no time
           & Character'Val (0) & Character'Val (255);                  --  no flags; unknown system
         if Padding > 0 then
            Output (Head + 10 .. Head + 9 + Padding) := [others => 'x'];
            Output (Head + 10 + Padding) := Character'Val (0);
         end if;
         Deflate.Compress (Work, Input, Output (Head + Head_Length .. Tail - 1), Data_Last, Fits);
         if not Fits then
            return;
         end if;
         pragma Assert (Data_Last <= Tail - 1 and then Data_Last + 8 <= Output'Last);
         pragma Assert (Data_Last >= Output'First - 1);
         declare
            Check : constant Unsigned_32 := Crc_32 (Input);
            Size  : constant Unsigned_32 := Unsigned_32 (Input'Length mod 2 ** 32);
         begin
            for Index in 0 .. 3 loop
               Output (Data_Last + 1 + Index) := Character'Val (Shift_Right (Check, 8 * Index) and 16#FF#);
               Output (Data_Last + 5 + Index) := Character'Val (Shift_Right (Size, 8 * Index) and 16#FF#);
            end loop;
            Last := Data_Last + 8;
         end;
      end;
   end Compress;

end Sparrow.Gzip;
