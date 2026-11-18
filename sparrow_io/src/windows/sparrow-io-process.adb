--  The process on Windows: Winsock start-up, the system clocks, the console.
--
--  UNTESTED: written from the Windows SDK headers, compiled but never run (no Windows machine was at hand).
with Ada.Environment_Variables;
with GNAT.OS_Lib;
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with System.Multiprocessors;

package body Sparrow.IO.Process with SPARK_Mode => Off, Refined_State => (Start_Up => null) is

   procedure GetSystemTimePreciseAsFileTime (Time : access Unsigned_64)
      with Import, Convention => Stdcall, External_Name => "GetSystemTimePreciseAsFileTime";
   function GetTickCount64 return Unsigned_64
      with Import, Convention => Stdcall, External_Name => "GetTickCount64";
   function WSAStartup (Version : Unsigned_16; Data : System.Address) return int
      with Import, Convention => Stdcall, External_Name => "WSAStartup";

   --  100-nanosecond ticks from 1601-01-01 to 1970-01-01
   Unix_Epoch_Ticks : constant := 116_444_736_000_000_000;

   function Microseconds_Now return Long_Long_Integer is
      Ticks : aliased Unsigned_64 := 0;
   begin
      GetSystemTimePreciseAsFileTime (Ticks'Access);
      return (if Ticks < Unix_Epoch_Ticks then 0 else Long_Long_Integer ((Ticks - Unix_Epoch_Ticks) / 10));
   end Microseconds_Now;

   procedure Read_Clock (Now : out Unix_Seconds) is begin
      Now := Unix_Seconds (Long_Long_Integer'Min (10 ** 15, Microseconds_Now / 1_000_000));
   end Read_Clock;

   procedure Read_Clock (Now : out Unix_Microseconds) is begin
      Now := Unix_Microseconds (Long_Long_Integer'Min (10 ** 18, Microseconds_Now));
   end Read_Clock;

   procedure Read_Monotonic (Now : out Milliseconds) is begin
      Now := Milliseconds (Unsigned_64'Min (GetTickCount64, 2 ** 62));
   end Read_Monotonic;

   procedure Sleep (Time : Milliseconds) is begin
      if Time > 0 then
         delay Duration (Milliseconds'Min (Time, 86_400_000)) / 1000;
      end if;
   end Sleep;

   --  Text, at most 64 KiB of it, indexed from 1.
   function Normalized (Text : String) return Environment_Text is
      Kept : constant Natural := Natural'Min (Text'Length, 65_536);
      Copy : constant String (1 .. Kept) := Text (Text'First .. Text'First + Kept - 1);
   begin
      return Copy;
   end Normalized;

   function Environment (Name : String) return Environment_Text is (Environment (Name, Default => ""));

   function Environment (Name : String; Default : String) return Environment_Text is begin
      if Name'Length = 0 or else not Ada.Environment_Variables.Exists (Name)
        or else Ada.Environment_Variables.Value (Name)'Length = 0
      then
         return Normalized (Default);
      end if;
      return Normalized (Ada.Environment_Variables.Value (Name));
   end Environment;

   function Processor_Count return Positive is (Positive (System.Multiprocessors.Number_Of_CPUs));

   procedure Prepare_Networking (Ready : out Boolean) is
      Data : aliased String (1 .. 512);   --  WSADATA, which the call fills and nothing here reads
   begin
      Ready := WSAStartup (16#0202#, Data'Address) = 0;
   end Prepare_Networking;

   --  Winsock has no per-process limit on sockets to raise.
   procedure Raise_Descriptor_Limit (Limit : out Natural) is begin
      Limit := 1_000_000;
   end Raise_Descriptor_Limit;

   procedure Log (Message : String) is
      Line    : constant String := Message & ASCII.CR & ASCII.LF;
      Written : Integer;
   begin
      Written := GNAT.OS_Lib.Write (GNAT.OS_Lib.Standerr, Line'Address, Line'Length);
      pragma Unreferenced (Written);
   end Log;

   procedure Write_Error (Data : String) is
      Next    : Natural := Data'First;
      Written : Integer;
   begin
      while Next <= Data'Last loop
         Written := GNAT.OS_Lib.Write (GNAT.OS_Lib.Standerr, Data (Next)'Address, Data'Last - Next + 1);
         exit when Written <= 0;
         Next := Next + Written;
      end loop;
   end Write_Error;

   procedure Stop (Code : Integer) is begin
      GNAT.OS_Lib.OS_Exit (Code);
   end Stop;

end Sparrow.IO.Process;
