package body Sparrow.IO.Winsock is

   function Classify (Code : int) return Error is
      Kind : constant Error_Kind :=
        (case Code is
            when WSAEWOULDBLOCK                                              => Would_Block,
            when WSAEINTR                                                    => Interrupted,
            when WSAECONNABORTED | WSAECONNRESET | WSAENOTCONN | WSAESHUTDOWN => Connection_Closed,
            when WSAECONNREFUSED                                             => Connection_Refused,
            when WSAETIMEDOUT | WSAEINPROGRESS                               => Timed_Out,
            when WSAEADDRINUSE                                               => Address_In_Use,
            when WSAEACCES                                                   => Not_Permitted,
            when WSAEMFILE                                                   => Out_Of_Descriptors,
            when WSAENOBUFS                                                  => Out_Of_Memory,
            when others                                                      => Other);
   begin
      return (Kind => Kind, Code => Integer (Code));
   end Classify;

   function Last_Failure return Error is (Classify (WSAGetLastError));

   function Set_Non_Blocking (Socket : Socket_Handle) return Boolean is
      Enabled : aliased unsigned_long := 1;
   begin
      return C_Ioctlsocket (Socket, FIONBIO, Enabled'Access) = 0;
   end Set_Non_Blocking;

end Sparrow.IO.Winsock;
