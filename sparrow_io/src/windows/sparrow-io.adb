--  Windows: every Descriptor is a socket.
--
--  UNTESTED: written from the Windows SDK headers, compiled but never run (no Windows machine was at hand).
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Winsock; use Sparrow.IO.Winsock;

package body Sparrow.IO with SPARK_Mode => Off, Refined_State => (Kernel => null) is

   function Message (Result : Error) return String is
     (case Result.Code is
         when 0               => "no error",
         when WSAEWOULDBLOCK  => "the operation would block",
         when WSAEINTR        => "interrupted",
         when WSAECONNABORTED => "connection aborted",
         when WSAECONNRESET   => "connection reset by peer",
         when WSAENOTCONN     => "not connected",
         when WSAESHUTDOWN    => "the socket was shut down",
         when WSAECONNREFUSED => "connection refused",
         when WSAETIMEDOUT    => "timed out",
         when WSAEADDRINUSE   => "address already in use",
         when WSAEACCES       => "permission denied",
         when WSAEMFILE       => "too many open sockets",
         when WSAENOBUFS      => "no buffer space available",
         when others          => "Winsock error" & Result.Code'Image);

   procedure Close (Item : Descriptor) is begin
      if Item /= No_Descriptor and then C_Closesocket (To_Handle (Item)) /= 0 then
         null;   --  the socket is released even when closesocket reports an error
      end if;
   end Close;

end Sparrow.IO;
