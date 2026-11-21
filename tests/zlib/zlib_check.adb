with Ada.Unchecked_Deallocation;
with Interfaces;
with Interfaces.C; use Interfaces.C;
with System;

package body Zlib_Check is

   Z_Finish     : constant := 4;
   Z_Stream_End : constant := 1;

   function Zlib_Version return System.Address
      with Import, Convention => C, External_Name => "zlibVersion";
   function Compile_Flags return unsigned_long
      with Import, Convention => C, External_Name => "zlibCompileFlags";

   --  Inflate with z_stream laid out for a zlib whose uLong is Long_Word (C's long differs between systems:
   --  32 bits on 64-bit Windows).
   generic
      type Long_Word is mod <>;
   function Inflate_With (Data : String; Limit : Positive) return String;

   function Inflate_With (Data : String; Limit : Positive) return String is
      type Z_Stream is record
         Next_In   : System.Address := System.Null_Address;
         Avail_In  : unsigned := 0;
         Total_In  : Long_Word := 0;
         Next_Out  : System.Address := System.Null_Address;
         Avail_Out : unsigned := 0;
         Total_Out : Long_Word := 0;
         Msg       : System.Address := System.Null_Address;
         State     : System.Address := System.Null_Address;
         Zalloc    : System.Address := System.Null_Address;
         Zfree     : System.Address := System.Null_Address;
         Opaque    : System.Address := System.Null_Address;
         Data_Type : int := 0;
         Adler     : Long_Word := 0;
         Reserved  : Long_Word := 0;
      end record with Convention => C;

      function Inflate_Init (Stream : access Z_Stream; Window_Bits : int; Version : System.Address; Size : int)
        return int
         with Import, Convention => C, External_Name => "inflateInit2_";
      function Inflate (Stream : access Z_Stream; Flush : int) return int
         with Import, Convention => C, External_Name => "inflate";
      function Inflate_End (Stream : access Z_Stream) return int
         with Import, Convention => C, External_Name => "inflateEnd";

      type String_Access is access String;
      procedure Free is new Ada.Unchecked_Deallocation (String, String_Access);

      Stream : aliased Z_Stream;
      Output : String_Access := new String (1 .. Limit);
      Input  : aliased constant String := Data & ' ';   --  never empty, so it has an address
      Result : int;
   begin
      --  31: gzip. Version and size are checked by inflateInit2_ against the library's own; the size is C's
      --  sizeof, trailing padding included, which 'Size leaves out.
      Result := Inflate_Init (Stream'Access, 31, Zlib_Version, int (Z_Stream'Object_Size / 8));
      if Result /= 0 then
         Free (Output);
         raise Not_Gzip with "inflateInit2 failed:" & Result'Image & " (z_stream of"
                             & int'Image (Z_Stream'Object_Size / 8) & " bytes)";
      end if;
      Stream.Next_In   := Input (Input'First)'Address;
      Stream.Avail_In  := unsigned (Data'Length);
      Stream.Next_Out  := Output (1)'Address;
      Stream.Avail_Out := unsigned (Limit);
      Result := Inflate (Stream'Access, Z_Finish);
      declare
         Produced : constant Natural := Limit - Natural (Stream.Avail_Out);
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
   end Inflate_With;

   function Inflate_32 is new Inflate_With (Interfaces.Unsigned_32);
   function Inflate_64 is new Inflate_With (Interfaces.Unsigned_64);

   function Inflated (Data : String; Limit : Positive := 64_000_000) return String is
      --  zlibCompileFlags, bits 2 and 3: the size of uLong (1: 32 bits, 2: 64 bits).
      Long_Size : constant unsigned_long := (Compile_Flags / 4) mod 4;
   begin
      return (if Long_Size = 1 then Inflate_32 (Data, Limit) else Inflate_64 (Data, Limit));
   end Inflated;

end Zlib_Check;
