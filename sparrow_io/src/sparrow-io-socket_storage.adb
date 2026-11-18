package body Sparrow.IO.Socket_Storage with SPARK_Mode is

   procedure Encode
     (Address : IP_Address; Port : Unsigned_16; Using : Layout; Into : out Storage; Length : out Positive)
   is
      Raw : constant Byte_Array := Bytes (Address);
   begin
      Into   := [others => 0];
      Length := (if Raw'Length = 4 then 16 else 28);
      if Using.Length_Byte then
         Into (1) := Unsigned_8 (Length);
         Into (2) := Family_Code (Address, Using);
      else
         Into (1) := Family_Code (Address, Using);
         Into (2) := 0;
      end if;
      Into (3) := Unsigned_8 (Shift_Right (Port, 8));
      Into (4) := Unsigned_8 (Port and 255);
      if Raw'Length = 4 then
         Into (5 .. 8) := Raw;
      else
         Into (9 .. 24) := Raw;
      end if;
   end Encode;

   procedure Decode
     (From : Storage; Using : Layout; Address : out IP_Address; Port : out Unsigned_16; Known : out Boolean)
   is
      Family : constant Unsigned_8 := (if Using.Length_Byte then From (2) else From (1));
   begin
      Port    := Unsigned_16 (From (3)) * 256 + Unsigned_16 (From (4));
      Known   := True;
      Address := Any_IPv4;
      if not Using.Length_Byte and then From (2) /= 0 then
         Known := False;
      elsif Family = AF_INET then
         Address := From_Bytes (From (5 .. 8));
      elsif Family = Using.Inet6_Family then
         Address := From_Bytes (From (9 .. 24));
      else
         Known := False;
      end if;
      if not Known then
         Port := 0;
      end if;
   end Decode;

end Sparrow.IO.Socket_Storage;
