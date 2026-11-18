--  The operating system as the rest of Sparrow sees it: descriptors, sockets, readiness events, clocks.
--
--  Portable by construction: the specs name no system call, constant or error number. Each has one body per
--  platform (src/linux: epoll and eventfd; src/bsd, for macOS and the BSDs: kqueue; src/windows: Winsock),
--  chosen by the crate's project file, and the raw bindings stay inside those bodies.
--
--  The specs are SPARK so proved code can call them: each contract states what the system guarantees (a read
--  never reports more bytes than the buffer holds), and the system's state is one external abstract state,
--  synchronized (every task may use it: the kernel serializes what it must). The bodies are thin system calls
--  outside SPARK. Nothing here raises: failures come back as values.
package Sparrow.IO
  with SPARK_Mode, Abstract_State => (Kernel with Synchronous, External), Initializes => Kernel
is

   --  A socket or another waitable object of the system: a file descriptor, or a handle on Windows.
   type Descriptor is range -1 .. 2 ** 63 - 1;
   No_Descriptor : constant Descriptor := -1;

   --  Why a call failed, in terms every platform has. Code is the system's own number (errno, or a Winsock
   --  error), for the log only.
   type Error_Kind is
     (None,
      Would_Block,          --  nothing to read, or no room to write, right now: wait for the next event
      Interrupted,          --  try again
      Connection_Closed,    --  reset, aborted or a broken pipe: the peer is gone
      Connection_Refused,
      Timed_Out,
      Address_In_Use,
      Not_Permitted,        --  such as binding a port below 1024
      Out_Of_Descriptors,   --  the process or the system is at its limit: stop accepting for a while
      Out_Of_Memory,
      Other);

   type Error is record
      Kind : Error_Kind := None;
      Code : Integer := 0;
   end record;

   No_Error : constant Error := (Kind => None, Code => 0);

   function Succeeded (Result : Error) return Boolean is (Result.Kind = None);

   --  The system's description of Result, for the log.
   function Message (Result : Error) return String
      with Global => null, Post => Message'Result'Length <= 200;

   procedure Close (Item : Descriptor) with Global => (In_Out => Kernel);

end Sparrow.IO;
