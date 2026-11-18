--  The process and its surroundings: clocks, the environment, limits, the log.
--
--  SPARK spec, system-call bodies (see Sparrow.IO). What the process is given as it starts is the state
--  Start_Up, fixed afterwards, so reading it is not a volatile read.
with Sparrow.Times; use Sparrow.Times;

package Sparrow.IO.Process
  with SPARK_Mode, Abstract_State => Start_Up, Initializes => Start_Up
is

   ---------------------------------------------------------------------------------------------------------------
   --  clocks (the cheapest the system has: a few milliseconds of resolution)

   procedure Read_Clock (Now : out Unix_Seconds)
      with Global => (In_Out => Kernel), Post => Now in 0 .. 10 ** 15;

   procedure Read_Clock (Now : out Unix_Microseconds)
      with Global => (In_Out => Kernel), Post => Now in 0 .. 10 ** 18;

   procedure Read_Monotonic (Now : out Milliseconds)
      with Global => (In_Out => Kernel), Post => Now in 0 .. 2 ** 62;

   --  The calling thread sleeps.
   procedure Sleep (Time : Milliseconds) with Global => (In_Out => Kernel);

   ---------------------------------------------------------------------------------------------------------------
   --  start-up

   --  An environment variable's value ("" when unset, cut at 64 KiB). Bytes: nothing says they are UTF-8.
   subtype Environment_Text is String
      with Dynamic_Predicate => Environment_Text'First = 1 and then Environment_Text'Length <= 65_536;
   function Environment (Name : String) return Environment_Text with Global => Start_Up;
   function Environment (Name : String; Default : String) return Environment_Text
      with Global => Start_Up, Pre => Default'First = 1 and then Default'Length <= 65_536;

   --  The processors this process may run on, at least 1.
   function Processor_Count return Positive with Global => Start_Up;

   ---------------------------------------------------------------------------------------------------------------
   --  process-wide settings; call them before starting tasks

   --  Start the system's networking where it needs starting (Winsock), and make a write to a closed socket
   --  an error value everywhere, never a signal. Every Sparrow program that opens a socket calls this first;
   --  calling it again does nothing.
   procedure Prepare_Networking (Ready : out Boolean) with Global => (In_Out => Kernel);

   --  The limit on open descriptors raised as far as the process is allowed; Limit is the limit now (where
   --  the system has no such limit, a large number).
   procedure Raise_Descriptor_Limit (Limit : out Natural) with Global => (In_Out => Kernel);

   ---------------------------------------------------------------------------------------------------------------
   --  the log, and the exit

   --  One line on standard error, written whole (lines of different tasks do not interleave).
   procedure Log (Message : String) with Global => (In_Out => Kernel);

   --  Data on standard error as it is, all of it: a batch of whole lines (Sparrow.Logs). A write the system
   --  cuts short or interrupts is continued; on an error the rest is dropped.
   procedure Write_Error (Data : String) with Global => (In_Out => Kernel);

   procedure Stop (Code : Integer) with Global => (In_Out => Kernel), No_Return;

end Sparrow.IO.Process;
