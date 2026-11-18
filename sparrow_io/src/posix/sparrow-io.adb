with GNAT.OS_Lib;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Posix;

package body Sparrow.IO with SPARK_Mode => Off, Refined_State => (Kernel => null) is

   -------------
   -- Message --
   -------------

   function Message (Result : Error) return String is
      Text : constant String := GNAT.OS_Lib.Errno_Message (Result.Code);
   begin
      return (if Text'Length <= 200 then Text else Text (Text'First .. Text'First + 199));
   end Message;

   -----------
   -- Close --
   -----------

   procedure Close (Item : Descriptor) is begin
      if Item /= No_Descriptor and then Posix.C_Close (int (Item)) /= 0 then
         null;   --  the descriptor is released even when close reports an error
      end if;
   end Close;

end Sparrow.IO;
