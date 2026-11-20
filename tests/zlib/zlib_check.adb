with Ada.Unchecked_Deallocation;
with Interfaces.C; use Interfaces.C;
with System;

package body Zlib_Check is

   type Z_Stream is record
      Next_In   : System.Address := System.Null_Address;
      Avail_In  : unsigned := 0;
      Total_In  : unsigned_long := 0;
      Next_Out  : System.Address := System.Null_Address;
      Avail_Out : unsigned := 0;
      Total_Out : unsigned_long := 0;
      Msg       : System.Address := System.Null_Address;
      State     : System.Address := System.Null_Address;
      Zalloc    : System.Address := System.Null_Address;
      Zfree     : System.Address := System.Null_Address;
      Opaque    : System.Address := System.Null_Address;
      Data_Type : int := 0;
      Adler     : unsigned_long := 0;
      Reserved  : unsigned_long := 0;
   end record with Convention => C;

   function Inflate_Init (Stream : access Z_Stream; Window_Bits : int; Version : System.Address; Size : int)
      return int
      with Import, Convention => C, External_Name => "inflateInit2_";
   function Zlib_Version return System.Address
      with Import, Convention => C, External_Name => "zlibVersion";
   function Inflate (Stream : access Z_Stream; Flush : int) return int
      with Import, Convention => C, External_Name => "inflate";
   function Inflate_End (Stream : access Z_Stream) return int
      with Import, Convention => C, External_Name => "inflateEnd";

   Z_Finish     : constant := 4;
   Z_Stream_End : constant := 1;

   function Inflated (Data : String; Limit : Positive := 64_000_000) return String is
      Stream : aliased Z_Stream;
      type String_Access is access String;
      procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);
      Output : String_Access := new String (1 .. Limit);
      Input  : aliased constant String := Data & ' ';   --  never empty, so it has an address
      Result : int;
   begin
      --  31: gzip. The version is the loaded library's own: inflateInit2_ refuses one it does not match.
      Result := Inflate_Init (Stream'Access, 31, Zlib_Version, int (Z_Stream'Size / 8));
      if Result /= 0 then
         raise Not_Gzip with "inflateInit2 failed:" & Result'Image;
      end if;
      Stream.Next_In   := Input (Input'First)'Address;
      Stream.Avail_In  := unsigned (Data'Length);
      Stream.Next_Out  := Output (1)'Address;
      Stream.Avail_Out := unsigned (Limit);
      Result := Inflate (Stream'Access, Z_Finish);
      declare
         Produced : constant Natural := Natural (Stream.Total_Out);
         Left     : constant unsigned := Stream.Avail_In;
      begin
         Result := (if Inflate_End (Stream'Access) = 0 then Result else -99);
         if Result /= Z_Stream_End or else Left /= 0 then
            Free (Output);
            raise Not_Gzip with (if Left /= 0 and then Result = Z_Stream_End then "bytes after the gzip member"
                                 else "inflate returned" & Result'Image);
         end if;
         return Copy : constant String := Output (1 .. Produced) do
            Free (Output);
         end return;
      end;
   end Inflated;

end Zlib_Check;
