--  What Linux (glibc or musl, x86-64 or AArch64) numbers and lays out differently from the BSDs: the rest of
--  the POSIX bodies (../posix) are written against this.
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Socket_Storage;
with System;

private package Sparrow.IO.Platform is

   type Int_Access is access all int with Convention => C;
   function Errno_Location return Int_Access
      with Import, Convention => C, External_Name => "__errno_location";

   --  errno values
   EPERM        : constant := 1;
   EINTR        : constant := 4;
   EAGAIN       : constant := 11;
   ENOMEM       : constant := 12;
   EACCES       : constant := 13;
   ENFILE       : constant := 23;
   EMFILE       : constant := 24;
   EPIPE        : constant := 32;
   EADDRINUSE   : constant := 98;
   ECONNABORTED : constant := 103;
   ECONNRESET   : constant := 104;
   ENOBUFS      : constant := 105;
   ENOTCONN     : constant := 107;
   ETIMEDOUT    : constant := 110;
   ECONNREFUSED : constant := 111;
   EINPROGRESS  : constant := 115;

   O_NONBLOCK : constant := 8#4000#;

   SOL_SOCKET   : constant := 1;
   SO_REUSEADDR : constant := 2;
   SO_RCVTIMEO  : constant := 20;
   SO_SNDTIMEO  : constant := 21;
   SO_NOSIGPIPE : constant := 0;    --  none: SIGPIPE is ignored instead (Prepare_Networking)

   --  The option that spreads one port's connections over several listeners, if the kernel has one.
   SO_SHARE_PORT  : constant := 15;  --  SO_REUSEPORT
   Balances_Ports : constant Boolean := True;

   --  How socket addresses are laid out (Sparrow.IO.Socket_Storage): a 16-bit family.
   AF_INET6       : constant := 10;
   IPV6_V6ONLY    : constant := 26;
   Storage_Layout : constant Socket_Storage.Layout := (Inet6_Family => AF_INET6, Length_Byte => False);

   --  struct addrinfo
   type Address_Info;
   type Address_Info_Access is access all Address_Info with Convention => C;
   type Address_Info is record
      Flags          : int := 0;
      Family         : int := 0;
      Socket_Type    : int := 0;
      Protocol       : int := 0;
      Address_Length : unsigned := 0;
      Address        : System.Address := System.Null_Address;
      Canonical_Name : System.Address := System.Null_Address;
      Next           : Address_Info_Access;
   end record with Convention => C;

   CLOCK_REALTIME_FAST  : constant int := 5;   --  CLOCK_REALTIME_COARSE
   CLOCK_MONOTONIC_FAST : constant int := 6;   --  CLOCK_MONOTONIC_COARSE
   RLIMIT_NOFILE        : constant := 7;
   Max_Descriptor_Limit : constant := 4_000_000;

end Sparrow.IO.Platform;
