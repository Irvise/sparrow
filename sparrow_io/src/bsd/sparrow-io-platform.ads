--  What macOS and FreeBSD (x86-64 or AArch64) number and lay out differently from Linux: the rest of the POSIX
--  bodies (../posix) are written against this. OpenBSD and NetBSD share these values except where noted.
--
--  UNTESTED: written from the systems' headers, compiled but never run (no BSD machine was at hand).
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow_Io_Config;
with Sparrow.IO.Socket_Storage;
with System;

private package Sparrow.IO.Platform is

   Mac : constant Boolean := Sparrow_Io_Config.Alire_Host_OS = "macos";

   type Int_Access is access all int with Convention => C;
   function Errno_Location return Int_Access
      with Import, Convention => C, External_Name => "__error";

   --  errno values
   EPERM        : constant := 1;
   EINTR        : constant := 4;
   ENOMEM       : constant := 12;
   EACCES       : constant := 13;
   ENFILE       : constant := 23;
   EMFILE       : constant := 24;
   EPIPE        : constant := 32;
   EAGAIN       : constant := 35;
   EINPROGRESS  : constant := 36;
   EADDRINUSE   : constant := 48;
   ECONNABORTED : constant := 53;
   ECONNRESET   : constant := 54;
   ENOBUFS      : constant := 55;
   ENOTCONN     : constant := 57;
   ETIMEDOUT    : constant := 60;
   ECONNREFUSED : constant := 61;

   O_NONBLOCK : constant := 4;

   SOL_SOCKET   : constant := 16#FFFF#;
   SO_REUSEADDR : constant := 16#0004#;
   SO_SNDTIMEO  : constant := 16#1005#;
   SO_RCVTIMEO  : constant := 16#1006#;
   SO_NOSIGPIPE : constant int := (if Mac then 16#1022# else 0);   --  FreeBSD: SIGPIPE is ignored instead

   --  FreeBSD 12+ balances connections with SO_REUSEPORT_LB; macOS's SO_REUSEPORT does not, so there the
   --  reactors share one listener.
   SO_SHARE_PORT  : constant int := (if Mac then 16#0200# else 16#0001_0000#);
   Balances_Ports : constant Boolean := not Mac;

   --  How socket addresses are laid out (Sparrow.IO.Socket_Storage): a length byte, then an 8-bit family.
   AF_INET6       : constant := (if Mac then 30 else 28);
   IPV6_V6ONLY    : constant := 27;
   Storage_Layout : constant Socket_Storage.Layout := (Inet6_Family => AF_INET6, Length_Byte => True);

   --  struct addrinfo: the canonical name comes before the address, unlike glibc
   type Address_Info;
   type Address_Info_Access is access all Address_Info with Convention => C;
   type Address_Info is record
      Flags          : int := 0;
      Family         : int := 0;
      Socket_Type    : int := 0;
      Protocol       : int := 0;
      Address_Length : unsigned := 0;
      Canonical_Name : System.Address := System.Null_Address;
      Address        : System.Address := System.Null_Address;
      Next           : Address_Info_Access;
   end record with Convention => C;

   CLOCK_REALTIME_FAST  : constant int := (if Mac then 0 else 10);    --  FreeBSD: CLOCK_REALTIME_FAST
   CLOCK_MONOTONIC_FAST : constant int := (if Mac then 6 else 12);    --  FreeBSD: CLOCK_MONOTONIC_FAST
   RLIMIT_NOFILE        : constant := 8;
   Max_Descriptor_Limit : constant := 10_240;   --  macOS refuses more than OPEN_MAX for the soft limit

end Sparrow.IO.Platform;
