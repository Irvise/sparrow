with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Posix; use Sparrow.IO.Posix;
with Sparrow_Io_Config;
with System;

package body Sparrow.IO.Events with SPARK_Mode => Off is

   --  epoll keeps the watch list itself.
   type Watch_List is null record;

   EPOLLIN       : constant := 16#001#;
   EPOLLOUT      : constant := 16#004#;
   EPOLLERR      : constant := 16#008#;
   EPOLLHUP      : constant := 16#010#;
   EPOLLRDHUP    : constant := 16#2000#;
   EPOLLET       : constant := 16#8000_0000#;
   EPOLL_CLOEXEC : constant := 8#2000000#;
   EPOLL_CTL_ADD : constant := 1;
   EPOLL_CTL_DEL : constant := 2;
   EPOLL_CTL_MOD : constant := 3;
   EFD_NONBLOCK  : constant := 8#4000#;
   EFD_CLOEXEC   : constant := 8#2000000#;

   --  struct epoll_event is { uint32 events; uint64 data; }: packed into 12 bytes on x86-64, 16 bytes with the
   --  data aligned everywhere else. Both are handled as 32-bit words: the events word, then the data's low
   --  word (little-endian) at Data_Word, which is where a descriptor goes.
   Packed    : constant Boolean := Sparrow_Io_Config.Alire_Host_Arch = "x86_64";
   Stride    : constant Positive := (if Packed then 3 else 4);
   Data_Word : constant Positive := (if Packed then 1 else 2);

   type Word_Array is array (Natural range <>) of aliased Unsigned_32 with Convention => C;

   function C_Epoll_Create1 (Flags : int) return int
      with Import, Convention => C, External_Name => "epoll_create1";
   function C_Epoll_Ctl (Epoll : int; Operation : int; File : int; Event : System.Address) return int
      with Import, Convention => C, External_Name => "epoll_ctl";
   function C_Epoll_Wait (Epoll : int; Events : System.Address; Max_Events, Timeout : int) return int
      with Import, Convention => C, External_Name => "epoll_wait";
   function C_Eventfd (Initial : unsigned; Flags : int) return int
      with Import, Convention => C, External_Name => "eventfd";

   ---------------------
   -- Reports_Changes --
   ---------------------

   function Reports_Changes return Boolean is (True);

   ----------
   -- Open --
   ----------

   procedure Open (This : in out Poller; Failure : out Error) is
      Handle : constant int := C_Epoll_Create1 (EPOLL_CLOEXEC);
   begin
      if Handle < 0 then
         Failure := Last_Failure;
         if Failure.Kind = None then
            Failure.Kind := Other;
         end if;
      else
         This.Handle := Descriptor (Handle);
         This.Open   := True;
         Failure     := No_Error;
      end if;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (This : in out Poller) is begin
      Sparrow.IO.Close (This.Handle);
      This.Handle := No_Descriptor;
      This.Open   := False;
   end Close;

   procedure Control (This : Poller; Operation : int; Item : Descriptor; Wanted : Interest) is
      Event : aliased Word_Array (0 .. 3) := [others => 0];
   begin
      Event (0) := EPOLLET or EPOLLRDHUP
        or (if Wanted.Readable then EPOLLIN else 0) or (if Wanted.Writable then EPOLLOUT else 0);
      Event (Data_Word) := Unsigned_32 (Item);
      if C_Epoll_Ctl (int (This.Handle), Operation, int (Item), Event'Address) /= 0 then
         null;   --  a descriptor that cannot be watched is never reported; its owner times it out
      end if;
   end Control;

   -----------
   -- Watch --
   -----------

   procedure Watch (This : in out Poller; Item : Descriptor; Wanted : Interest := (others => <>)) is begin
      Control (This, EPOLL_CTL_ADD, Item, Wanted);
   end Watch;

   -------------
   -- Rewatch --
   -------------

   procedure Rewatch (This : in out Poller; Item : Descriptor; Wanted : Interest) is begin
      Control (This, EPOLL_CTL_MOD, Item, Wanted);
   end Rewatch;

   -------------
   -- Unwatch --
   -------------

   procedure Unwatch (This : in out Poller; Item : Descriptor) is begin
      Control (This, EPOLL_CTL_DEL, Item, (Readable => False, Writable => False));
   end Unwatch;

   ----------
   -- Wait --
   ----------

   procedure Wait (This : in out Poller; Into : in out Event_Array; Timeout : Milliseconds; Count : out Natural) is
      Raw  : aliased Word_Array (0 .. Into'Length * Stride - 1);
      Wait_For : constant int :=
        (if Timeout < 0 then -1 else int (Milliseconds'Min (Timeout, Milliseconds (int'Last))));
      Got  : constant int := C_Epoll_Wait (int (This.Handle), Raw'Address, int (Into'Length), Wait_For);
   begin
      Count := (if Got < 0 then 0 else Natural'Min (Natural (Got), Into'Length));   --  EINTR: an empty round
      for Index in 0 .. Count - 1 loop
         declare
            Mask : constant Unsigned_32 := Raw (Index * Stride);
         begin
            Into (Into'First + Index) :=
              (Item     => Descriptor (Raw (Index * Stride + Data_Word)),
               Readable => (Mask and EPOLLIN) /= 0,
               Writable => (Mask and EPOLLOUT) /= 0,
               Closed   => (Mask and (EPOLLERR or EPOLLHUP or EPOLLRDHUP)) /= 0);
         end;
      end loop;
   end Wait;

   ----------
   -- Open --
   ----------

   procedure Open (This : in out Waker; Failure : out Error) is
      Handle : constant int := C_Eventfd (0, EFD_NONBLOCK + EFD_CLOEXEC);
   begin
      if Handle < 0 then
         Failure := Last_Failure;
         if Failure.Kind = None then
            Failure.Kind := Other;
         end if;
      else
         This.Read_End  := Descriptor (Handle);
         This.Write_End := Descriptor (Handle);
         Failure        := No_Error;
      end if;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (This : in out Waker) is begin
      Sparrow.IO.Close (This.Read_End);
      This.Read_End  := No_Descriptor;
      This.Write_End := No_Descriptor;
   end Close;

   --  One write of an eventfd increment; all it needs is the descriptor, so a signal handler can call it.
   procedure Raise_Counter (File : int) is
      One     : aliased Unsigned_64 := 1;
      Written : long;
   begin
      Written := C_Write (File, One'Address, 8);
      pragma Unreferenced (Written);   --  a full counter is already signalled
   end Raise_Counter;

   ------------
   -- Signal --
   ------------

   procedure Signal (This : Waker) is begin
      Raise_Counter (int (This.Write_End));
   end Signal;

   -----------
   -- Drain --
   -----------

   procedure Drain (This : Waker) is
      Value : aliased Unsigned_64;
      Got   : long;
   begin
      Got := C_Read (int (This.Read_End), Value'Address, 8);
      pragma Unreferenced (Got);   --  nothing to read: already drained
   end Drain;

   ---------------------------
   -- Signal_On_Termination --
   ---------------------------

   Termination_File : int := -1 with Atomic;

   --  Runs as a signal handler: one write, which is async-signal-safe.
   procedure On_Termination (Signal_Number : int) with Convention => C;

   procedure On_Termination (Signal_Number : int) is
      pragma Unreferenced (Signal_Number);
      File : constant int := Termination_File;
   begin
      if File >= 0 then
         Raise_Counter (File);
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
