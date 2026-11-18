with Ada.Environment_Variables;
with GNAT.OS_Lib;
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Platform; use Sparrow.IO.Platform;
with Sparrow.IO.Posix; use Sparrow.IO.Posix;
with System.Multiprocessors;
with System.Storage_Elements;

package body Sparrow.IO.Process with SPARK_Mode => Off, Refined_State => (Start_Up => null) is

   type Time_Spec is record
      Seconds     : long;
      Nanoseconds : long;
   end record with Convention => C;

   function C_Clock_Gettime (Clock : int; Time : access Time_Spec) return int
      with Import, Convention => C, External_Name => "clock_gettime";

   type Resource_Limit is record
      Current, Maximum : Unsigned_64;
   end record with Convention => C;

   function C_Getrlimit (Resource : int; Limit : access Resource_Limit) return int
      with Import, Convention => C, External_Name => "getrlimit";
   function C_Setrlimit (Resource : int; Limit : access Resource_Limit) return int
      with Import, Convention => C, External_Name => "setrlimit";
   SIG_IGN : constant := 1;

   function Read (Clock : int) return Time_Spec is
      Time : aliased Time_Spec := (0, 0);
   begin
      if C_Clock_Gettime (Clock, Time'Access) /= 0 then
         return (0, 0);   --  cannot happen for these clocks
      end if;
      return Time;
   end Read;

   ----------------
   -- Read_Clock --
   ----------------

   procedure Read_Clock (Now : out Unix_Seconds) is
      Time : constant Time_Spec := Read (CLOCK_REALTIME_FAST);
   begin
      Now := Unix_Seconds'Max (0, Unix_Seconds'Min (10 ** 15, Unix_Seconds (Time.Seconds)));
   end Read_Clock;

   procedure Read_Clock (Now : out Unix_Microseconds) is
      Time : constant Time_Spec := Read (CLOCK_REALTIME_FAST);
   begin
      Now := Unix_Microseconds'Max
        (0, Unix_Microseconds'Min
           (10 ** 18, Unix_Microseconds (Time.Seconds) * 1_000_000 + Unix_Microseconds (Time.Nanoseconds) / 1000));
   end Read_Clock;

   --------------------
   -- Read_Monotonic --
   --------------------

   procedure Read_Monotonic (Now : out Milliseconds) is
      Time : constant Time_Spec := Read (CLOCK_MONOTONIC_FAST);
   begin
      Now := Milliseconds'Max
        (0, Milliseconds'Min
           (2 ** 62, Milliseconds (Time.Seconds) * 1000 + Milliseconds (Time.Nanoseconds) / 1_000_000));
   end Read_Monotonic;

   -----------
   -- Sleep --
   -----------

   procedure Sleep (Time : Milliseconds) is begin
      if Time > 0 then
         delay Duration (Milliseconds'Min (Time, 86_400_000)) / 1000;
      end if;
   end Sleep;

   -----------------
   -- Environment --
   -----------------

   function Environment (Name : String) return Environment_Text is
     (Environment (Name, Default => ""));

   --  Text, at most 64 KiB of it, indexed from 1.
   function Normalized (Text : String) return Environment_Text is
      Kept : constant Natural := Natural'Min (Text'Length, 65_536);
      Copy : constant String (1 .. Kept) := Text (Text'First .. Text'First + Kept - 1);
   begin
      return Copy;
   end Normalized;

   function Environment (Name : String; Default : String) return Environment_Text is begin
      if Name'Length = 0 or else not Ada.Environment_Variables.Exists (Name)
        or else Ada.Environment_Variables.Value (Name)'Length = 0
      then
         return Normalized (Default);
      end if;
      return Normalized (Ada.Environment_Variables.Value (Name));
   end Environment;

   ---------------------
   -- Processor_Count --
   ---------------------

   function Processor_Count return Positive is (Positive (System.Multiprocessors.Number_Of_CPUs));

   ------------------------
   -- Prepare_Networking --
   ------------------------

   procedure Prepare_Networking (Ready : out Boolean) is
      Previous : System.Address;
   begin
      Previous := C_Signal (SIGPIPE, System.Storage_Elements.To_Address (SIG_IGN));
      pragma Unreferenced (Previous);
      Ready := True;
   end Prepare_Networking;

   ----------------------------
   -- Raise_Descriptor_Limit --
   ----------------------------

   procedure Raise_Descriptor_Limit (Limit : out Natural) is
      Now : aliased Resource_Limit;
   begin
      Limit := 1024;
      if C_Getrlimit (RLIMIT_NOFILE, Now'Access) /= 0 then
         return;
      end if;

      if Now.Current < Unsigned_64'Min (Now.Maximum, Max_Descriptor_Limit) then
         Now.Current := Unsigned_64'Min (Now.Maximum, Max_Descriptor_Limit);
         if C_Setrlimit (RLIMIT_NOFILE, Now'Access) /= 0 or else C_Getrlimit (RLIMIT_NOFILE, Now'Access) /= 0 then
            null;   --  keep whatever the soft limit is
         end if;
      end if;

      Limit := Natural (Unsigned_64'Min (Now.Current, Max_Descriptor_Limit));
   end Raise_Descriptor_Limit;

   ---------
   -- Log --
   ---------

   procedure Log (Message : String) is
      Line    : constant String := Message & ASCII.LF;
      Written : long;
   begin
      Written := C_Write (2, Line (Line'First)'Address, size_t (Line'Length));   --  one write: the line stays whole
      pragma Unreferenced (Written);
   end Log;

   procedure Write_Error (Data : String) is
      Next    : Natural := Data'First;
      Written : long;
   begin
      while Next <= Data'Last loop
         Written := C_Write (2, Data (Next)'Address, size_t (Data'Last - Next + 1));
         if Written > 0 then
            Next := Next + Natural (Written);
         elsif Written < 0 and then Last_Errno = EINTR then
            null;
         else
            exit;
         end if;
      end loop;
   end Write_Error;

   ----------
   -- Stop --
   ----------

   procedure Stop (Code : Integer) is begin
      GNAT.OS_Lib.OS_Exit (Code);
   end Stop;

end Sparrow.IO.Process;
