--  What the Windows bodies of Sparrow.IO share: Winsock's calls, constants and error codes. A Descriptor is a
--  SOCKET (every descriptor Sparrow.IO makes on Windows is a socket, the Waker's included).
--
--  UNTESTED: written from the Windows SDK headers, compiled but never run (no Windows machine was at hand).
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with System;

private package Sparrow.IO.Winsock is

   type Socket_Handle is new Unsigned_64;   --  SOCKET (UINT_PTR) on 64-bit Windows
   Invalid_Socket : constant Socket_Handle := Socket_Handle'Last;
   Socket_Error   : constant := -1;

   function To_Handle (Item : Descriptor) return Socket_Handle is (Socket_Handle (Item));
   function To_Descriptor (Item : Socket_Handle) return Descriptor is
     (if Item = Invalid_Socket or else Item > Socket_Handle (Descriptor'Last) then No_Descriptor
      else Descriptor (Item));

   AF_INET      : constant := 2;
   SOCK_STREAM  : constant := 1;
   IPPROTO_TCP  : constant := 6;
   TCP_NODELAY  : constant := 1;
   SOL_SOCKET   : constant := 16#FFFF#;
   SO_SNDTIMEO  : constant := 16#1005#;
   SO_RCVTIMEO  : constant := 16#1006#;
   SO_EXCLUSIVEADDRUSE : constant := -5;   --  ~SO_REUSEADDR: no other socket may take the port
   FIONBIO      : constant := -2_147_195_266;   --  0x8004667E as a long

   WSAEINTR        : constant := 10_004;
   WSAEACCES       : constant := 10_013;
   WSAEMFILE       : constant := 10_024;
   WSAEWOULDBLOCK  : constant := 10_035;
   WSAEINPROGRESS  : constant := 10_036;
   WSAEADDRINUSE   : constant := 10_048;
   WSAECONNABORTED : constant := 10_053;
   WSAECONNRESET   : constant := 10_054;
   WSAENOBUFS      : constant := 10_055;
   WSAENOTCONN     : constant := 10_057;
   WSAESHUTDOWN    : constant := 10_058;
   WSAETIMEDOUT    : constant := 10_060;
   WSAECONNREFUSED : constant := 10_061;

   --  struct sockaddr_in
   type Socket_Address is record
      Family  : Unsigned_16 := AF_INET;
      Port    : Unsigned_16 := 0;   --  network byte order
      Address : Unsigned_32 := 0;   --  network byte order
      Padding : Unsigned_64 := 0;
   end record with Convention => C;

   function C_Socket (Domain, Kind, Protocol : int) return Socket_Handle
      with Import, Convention => Stdcall, External_Name => "socket";
   function C_Closesocket (Socket : Socket_Handle) return int
      with Import, Convention => Stdcall, External_Name => "closesocket";
   function C_Ioctlsocket (Socket : Socket_Handle; Command : long; Argument : access unsigned_long) return int
      with Import, Convention => Stdcall, External_Name => "ioctlsocket";
   function C_Setsockopt (Socket : Socket_Handle; Level, Name : int; Value : System.Address; Length : int) return int
      with Import, Convention => Stdcall, External_Name => "setsockopt";
   function C_Bind (Socket : Socket_Handle; Address : System.Address; Length : int) return int
      with Import, Convention => Stdcall, External_Name => "bind";
   function C_Listen (Socket : Socket_Handle; Backlog : int) return int
      with Import, Convention => Stdcall, External_Name => "listen";
   function C_Accept (Socket : Socket_Handle; Address, Length : System.Address) return Socket_Handle
      with Import, Convention => Stdcall, External_Name => "accept";
   function C_Connect (Socket : Socket_Handle; Address : System.Address; Length : int) return int
      with Import, Convention => Stdcall, External_Name => "connect";
   function C_Getsockname (Socket : Socket_Handle; Address : System.Address; Length : access int) return int
      with Import, Convention => Stdcall, External_Name => "getsockname";
   function C_Recv (Socket : Socket_Handle; Into : System.Address; Length : int; Flags : int) return int
      with Import, Convention => Stdcall, External_Name => "recv";
   function C_Send (Socket : Socket_Handle; From : System.Address; Length : int; Flags : int) return int
      with Import, Convention => Stdcall, External_Name => "send";
   function WSAGetLastError return int
      with Import, Convention => Stdcall, External_Name => "WSAGetLastError";

   --  The calling thread's last Winsock error as an Error; Kind is never None.
   function Last_Failure return Error;
   function Classify (Code : int) return Error;

   --  Make Socket non-blocking; False when Winsock refused.
   function Set_Non_Blocking (Socket : Socket_Handle) return Boolean;

   function Swap_Bytes (Value : Unsigned_32) return Unsigned_32 is
     (Shift_Left (Value and 255, 24) or Shift_Left (Shift_Right (Value, 8) and 255, 16)
      or Shift_Left (Shift_Right (Value, 16) and 255, 8) or Shift_Right (Value, 24));

end Sparrow.IO.Winsock;
