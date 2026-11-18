with GNAT.OS_Lib;
with Interfaces.C; use Interfaces.C;
with Interfaces.C.Strings;
with System;

package body Sparrow.Crypto with SPARK_Mode => Off is

   function CRYPTO_memcmp (Left, Right : System.Address; Length : size_t) return int
      with Import, Convention => C, External_Name => "CRYPTO_memcmp";

   function Constant_Time_Equal (Left, Right : String) return Boolean is
     (Left'Length = Right'Length
      and then (Left'Length = 0
                or else CRYPTO_memcmp (Left (Left'First)'Address, Right (Right'First)'Address,
                                       size_t (Left'Length)) = 0));

   function To_Hex (Data : String) return String is
      Hex_Digits : constant String (1 .. 16) := "0123456789abcdef";
      Result     : String (1 .. 2 * Data'Length);
   begin
      for Offset in 0 .. Data'Length - 1 loop
         Result (2 * Offset + 1) := Hex_Digits (Character'Pos (Data (Data'First + Offset)) / 16 + 1);
         Result (2 * Offset + 2) := Hex_Digits (Character'Pos (Data (Data'First + Offset)) mod 16 + 1);
      end loop;
      return Result;
   end To_Hex;

   function OpenSSL_version_num return unsigned_long
      with Import, Convention => C, External_Name => "OpenSSL_version_num";
   function OpenSSL_version (Kind : int) return Interfaces.C.Strings.chars_ptr
      with Import, Convention => C, External_Name => "OpenSSL_version";

begin
   declare
      Problem : constant String :=
        Version_Problem (Long_Long_Integer (OpenSSL_version_num), Interfaces.C.Strings.Value (OpenSSL_version (0)));
      Line    : constant String := "sparrow: " & Problem & ASCII.LF;
      Written : Integer;
   begin
      if Problem /= "" then
         Written := GNAT.OS_Lib.Write (GNAT.OS_Lib.Standerr, Line'Address, Line'Length);
         pragma Unreferenced (Written);
         GNAT.OS_Lib.OS_Exit (1);
      end if;
   end;
end Sparrow.Crypto;
