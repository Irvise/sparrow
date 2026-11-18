--  kqueue (macOS, FreeBSD): EV_CLEAR makes each filter report changes, as epoll's EPOLLET does. A pipe is the
--  Waker.
--
--  UNTESTED: written from the systems' headers, compiled but never run (no BSD machine was at hand).
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Platform;
with Sparrow.IO.Posix; use Sparrow.IO.Posix;
with System;

package body Sparrow.IO.Events with SPARK_Mode => Off is

   --  kqueue keeps the watch list itself.
   type Watch_List is null record;

   EVFILT_READ  : constant Unsigned_16 := 16#FFFF#;   --  -1
   EVFILT_WRITE : constant Unsigned_16 := 16#FFFE#;   --  -2
   EV_ADD       : constant Unsigned_16 := 16#0001#;
   EV_DELETE    : constant Unsigned_16 := 16#0002#;
   EV_CLEAR     : constant Unsigned_16 := 16#0020#;
   EV_ERROR     : constant Unsigned_16 := 16#4000#;
   EV_EOF       : constant Unsigned_16 := 16#8000#;

   --  struct kevent as 64-bit words: ident; filter, flags and fflags (little-endian, low to high); data;
   --  udata; and on FreeBSD 12+ four words of ext. 32 bytes on macOS, 64 on FreeBSD.
   Stride : constant Positive := (if Platform.Mac then 4 else 8);

   type Word_Array is array (Natural range <>) of aliased Unsigned_64 with Convention => C;

   type Time_Spec is record
      Seconds     : long;
      Nanoseconds : long;
   end record with Convention => C;

   function C_Kqueue return int with Import, Convention => C, External_Name => "kqueue";
   function C_Kevent
     (Queue   : int;
      Changes : System.Address;
      Change_Count : int;
      Events  : System.Address;
      Event_Count : int;
      Timeout : System.Address) return int
      with Import, Convention => C, External_Name => "kevent";

   function Failed return Error is
      Result : Error := Last_Failure;
   begin
      if Result.Kind = None then
         Result.Kind := Other;
      end if;
      return Result;
   end Failed;

   function Reports_Changes return Boolean is (True);

   procedure Open (This : in out Poller; Failure : out Error) is
      Handle : constant int := C_Kqueue;
   begin
      if Handle < 0 then
         Failure := Failed;
      elsif not Prepare_Descriptor (Handle, Non_Blocking => False) then
         Failure := Failed;
         Sparrow.IO.Close (Descriptor (Handle));
      else
         This.Handle := Descriptor (Handle);
         This.Open   := True;
         Failure     := No_Error;
      end if;
   end Open;

   procedure Close (This : in out Poller) is begin
      Sparrow.IO.Close (This.Handle);
      This.Handle := No_Descriptor;
      This.Open   := False;
   end Close;

   --  One change, on its own: kevent stops at the first change that fails, and deleting a filter that was
   --  never added fails.
   procedure Change (This : Poller; Item : Descriptor; Filter, Flags : Unsigned_16) is
      Change_Words : aliased Word_Array (0 .. Stride - 1) := [others => 0];
   begin
      Change_Words (0) := Unsigned_64 (Item);
      Change_Words (1) := Unsigned_64 (Filter) or Shift_Left (Unsigned_64 (Flags), 16);
      if C_Kevent (int (This.Handle), Change_Words'Address, 1, System.Null_Address, 0, System.Null_Address) < 0 then
         null;   --  a descriptor that cannot be watched is never reported; its owner times it out
      end if;
   end Change;

   procedure Apply (This : Poller; Item : Descriptor; Wanted : Interest) is begin
      Change (This, Item, EVFILT_READ, (if Wanted.Readable then EV_ADD or EV_CLEAR else EV_DELETE));
      Change (This, Item, EVFILT_WRITE, (if Wanted.Writable then EV_ADD or EV_CLEAR else EV_DELETE));
   end Apply;

   procedure Watch (This : in out Poller; Item : Descriptor; Wanted : Interest := (others => <>)) is begin
      Apply (This, Item, Wanted);
   end Watch;

   procedure Rewatch (This : in out Poller; Item : Descriptor; Wanted : Interest) is begin
      Apply (This, Item, Wanted);
   end Rewatch;

   procedure Unwatch (This : in out Poller; Item : Descriptor) is begin
      Apply (This, Item, (Readable => False, Writable => False));
   end Unwatch;

   procedure Wait (This : in out Poller; Into : in out Event_Array; Timeout : Milliseconds; Count : out Natural) is
      Raw     : aliased Word_Array (0 .. Into'Length * Stride - 1);
      Bound   : aliased Time_Spec :=
        (long (Milliseconds'Max (0, Timeout) / 1000), long (Milliseconds'Max (0, Timeout) mod 1000) * 1_000_000);
      Got     : constant int :=
        C_Kevent (int (This.Handle), System.Null_Address, 0, Raw'Address, int (Into'Length),
                  (if Timeout < 0 then System.Null_Address else Bound'Address));
   begin
      Count := (if Got < 0 then 0 else Natural'Min (Natural (Got), Into'Length));   --  EINTR: an empty round
      for Index in 0 .. Count - 1 loop
         declare
            Filter : constant Unsigned_16 := Unsigned_16 (Raw (Index * Stride + 1) and 16#FFFF#);
            Flags  : constant Unsigned_16 := Unsigned_16 (Shift_Right (Raw (Index * Stride + 1), 16) and 16#FFFF#);
         begin
            Into (Into'First + Index) :=
              (Item     => Descriptor (Raw (Index * Stride) and 16#7FFF_FFFF_FFFF_FFFF#),
               Readable => Filter = EVFILT_READ,
               Writable => Filter = EVFILT_WRITE,
               Closed   => (Flags and (EV_EOF or EV_ERROR)) /= 0);
         end;
      end loop;
   end Wait;

   ---------------------------------------------------------------------------------------------------------------
   --  Waker: a pipe

   procedure Open (This : in out Waker; Failure : out Error) is
      Ends : aliased array (1 .. 2) of int := [-1, -1];
   begin
      if C_Pipe (Ends'Address) /= 0 then
         Failure := Failed;
         return;
      end if;
      if not Prepare_Descriptor (Ends (1), Non_Blocking => True)
        or else not Prepare_Descriptor (Ends (2), Non_Blocking => True)
      then
         Failure := Failed;
         Sparrow.IO.Close (Descriptor (Ends (1)));
         Sparrow.IO.Close (Descriptor (Ends (2)));
         return;
      end if;
      This.Read_End  := Descriptor (Ends (1));
      This.Write_End := Descriptor (Ends (2));
      Failure        := No_Error;
   end Open;

   procedure Close (This : in out Waker) is begin
      Sparrow.IO.Close (This.Read_End);
      Sparrow.IO.Close (This.Write_End);
      This.Read_End  := No_Descriptor;
      This.Write_End := No_Descriptor;
   end Close;

   --  One byte into the pipe; all it needs is the descriptor, so a signal handler can call it.
   procedure Poke (File : int) is
      Byte    : aliased Character := 'w';
      Written : long;
   begin
      Written := C_Write (File, Byte'Address, 1);
      pragma Unreferenced (Written);   --  a full pipe is already signalled
   end Poke;

   procedure Signal (This : Waker) is begin
      Poke (int (This.Write_End));
   end Signal;

   procedure Drain (This : Waker) is
      Bytes : aliased String (1 .. 256);
   begin
      while C_Read (int (This.Read_End), Bytes'Address, Bytes'Length) > 0 loop
         null;
      end loop;
   end Drain;

   Termination_File : int := -1 with Atomic;

   --  Runs as a signal handler: one write, which is async-signal-safe.
   procedure On_Termination (Signal_Number : int) with Convention => C;

   procedure On_Termination (Signal_Number : int) is
      pragma Unreferenced (Signal_Number);
      File : constant int := Termination_File;
   begin
      if File >= 0 then
         Poke (File);
      end if;
   end On_Termination;

   procedure Signal_On_Termination (This : Waker) is
      Old_Interrupt, Old_Terminate : System.Address;
   begin
      Termination_File := int (This.Write_End);
      Old_Interrupt    := C_Signal (SIGINT, On_Termination'Address);
      Old_Terminate    := C_Signal (SIGTERM, On_Termination'Address);
      pragma Unreferenced (Old_Interrupt, Old_Terminate);
   end Signal_On_Termination;

end Sparrow.IO.Events;
