with Interfaces.C; use Interfaces.C;
with Sparrow.Base64;
with Sparrow.Crypto.Libcrypto; use Sparrow.Crypto.Libcrypto;
with System;

package body Sparrow.Crypto.Random with SPARK_Mode => Off, Refined_State => (Entropy => null) is

   function RAND_bytes (Into : System.Address; Count : int) return int
      with Import, Convention => C, External_Name => "RAND_bytes";

   procedure Fill (Into : out String) is
      Chunk : constant := 2 ** 20;
      First : Integer := Into'First;
   begin
      Into := [others => ASCII.NUL];
      while First <= Into'Last loop
         declare
            Count : constant Natural := Natural'Min (Chunk, Into'Last - First + 1);
         begin
            if RAND_bytes (Into (First)'Address, int (Count)) /= 1 then
               Fail ("RAND_bytes");
            end if;
            exit when Into'Last - First < Chunk;
            First := First + Count;
         end;
      end loop;
   end Fill;

   procedure Token (Byte_Count : Positive; Into : out String; Last : out Natural) is
      Bytes : String (1 .. Byte_Count);
   begin
      Fill (Bytes);
      Into := [others => ' '];
      declare
         Text : constant String := Base64.Encode (Bytes, Base64.Url_Safe);
      begin
         Last := 0;
         for Symbol of Text loop
            exit when Symbol = '=';
            Last        := Last + 1;
            Into (Last) := Symbol;
         end loop;
      end;
   end Token;

end Sparrow.Crypto.Random;
