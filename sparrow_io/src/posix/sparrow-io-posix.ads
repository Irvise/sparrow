--  The calls every POSIX body of Sparrow.IO makes, and errno. Platform says what differs between systems.
with Interfaces.C; use Interfaces.C;
with System;

private package Sparrow.IO.Posix is

   function Last_Errno return int;

   --  The calling thread's errno as an Error; Kind is never None (a failure with errno 0 is Other).
   function Last_Failure return Error;
   function Classify (Code : int) return Error;

   function C_Read (File : int; Into : System.Address; Count : size_t) return long
      with Import, Convention => C, External_Name => "read";
   function C_Write (File : int; From : System.Address; Count : size_t) return long
      with Import, Convention => C, External_Name => "write";
   function C_Close (File : int) return int
      with Import, Convention => C, External_Name => "close";
   function C_Pipe (Ends : System.Address) return int
      with Import, Convention => C, External_Name => "pipe";
   function C_Signal (Signal_Number : int; Handler : System.Address) return System.Address
      with Import, Convention => C, External_Name => "signal";

   SIGINT  : constant := 2;
   SIGPIPE : constant := 13;
   SIGTERM : constant := 15;

   --  Make File non-blocking (when asked) and close-on-exec; on macOS also keep a closed peer from raising
   --  SIGPIPE. False when the system refused.
   function Prepare_Descriptor (File : int; Non_Blocking : Boolean) return Boolean;

end Sparrow.IO.Posix;
