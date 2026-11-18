with Sparrow.IO.Platform; use Sparrow.IO.Platform;

package body Sparrow.IO.Posix is

   F_SETFD    : constant := 2;
   F_GETFL    : constant := 3;
   F_SETFL    : constant := 4;
   FD_CLOEXEC : constant := 1;

   function C_Fcntl (File : int; Command : int; Argument : int) return int
      with Import, Convention => C_Variadic_2, External_Name => "fcntl";
   function C_Setsockopt (Socket : int; Level, Name : int; Value : System.Address; Length : unsigned) return int
      with Import, Convention => C, External_Name => "setsockopt";

   function Last_Errno return int is (Errno_Location.all);

   function Classify (Code : int) return Error is
      Kind : constant Error_Kind :=
        (if Code = EAGAIN then Would_Block
         elsif Code = EINTR then Interrupted
         elsif Code in EPIPE | ECONNABORTED | ECONNRESET | ENOTCONN then Connection_Closed
         elsif Code = ECONNREFUSED then Connection_Refused
         elsif Code in ETIMEDOUT | EINPROGRESS then Timed_Out   --  EINPROGRESS: a connect past its bound
         elsif Code = EADDRINUSE then Address_In_Use
         elsif Code in EPERM | EACCES then Not_Permitted
         elsif Code in ENFILE | EMFILE then Out_Of_Descriptors
         elsif Code in ENOMEM | ENOBUFS then Out_Of_Memory
         else Other);
   begin
      return (Kind => Kind, Code => Integer (Code));
   end Classify;

   function Last_Failure return Error is (Classify (Last_Errno));

   function Prepare_Descriptor (File : int; Non_Blocking : Boolean) return Boolean is
      Flags   : constant int := C_Fcntl (File, F_GETFL, 0);
      Enabled : aliased int := 1;
   begin
      if Flags < 0 or else C_Fcntl (File, F_SETFD, FD_CLOEXEC) < 0 then
         return False;
      end if;
      if Non_Blocking and then (Flags / O_NONBLOCK) mod 2 = 0 and then C_Fcntl (File, F_SETFL, Flags + O_NONBLOCK) < 0
      then
         return False;
      end if;
      pragma Warnings (Off, "condition is always*");   --  on Linux there is no such option
      pragma Warnings (Off, "if statement has no effect");
      if SO_NOSIGPIPE /= 0 and then C_Setsockopt (File, SOL_SOCKET, SO_NOSIGPIPE, Enabled'Address, int'Size / 8) < 0
      then
         null;   --  a pipe has no such option; and SIGPIPE is ignored process-wide as well
      end if;
      pragma Warnings (On, "if statement has no effect");
      pragma Warnings (On, "condition is always*");
      return True;
   end Prepare_Descriptor;

end Sparrow.IO.Posix;
