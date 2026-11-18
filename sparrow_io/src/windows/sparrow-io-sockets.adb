--  Sockets over Winsock 2.
--
--  UNTESTED: written from the Windows SDK headers, compiled but never run (no Windows machine was at hand).
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Addresses; use Sparrow.IO.Addresses;
with Sparrow.IO.Socket_Storage;
with Sparrow.IO.Winsock; use Sparrow.IO.Winsock;
with System;

package body Sparrow.IO.Sockets with SPARK_Mode => Off is

   --  struct addrinfo (ADDRINFOA): the address length is a size_t here
   type Address_Info;
   type Address_Info_Access is access all Address_Info with Convention => C;
   type Address_Info is record
      Flags          : int := 0;
      Family         : int := 0;
      Socket_Type    : int := 0;
      Protocol       : int := 0;
      Address_Length : size_t := 0;
      Canonical_Name : System.Address := System.Null_Address;
      Address        : System.Address := System.Null_Address;
      Next           : Address_Info_Access;
   end record with Convention => C;

   function C_Getaddrinfo
     (Node : char_array; Service : System.Address; Hints : System.Address; Result : access Address_Info_Access)
      return int
      with Import, Convention => Stdcall, External_Name => "getaddrinfo";
   procedure C_Freeaddrinfo (Result : Address_Info_Access)
      with Import, Convention => Stdcall, External_Name => "freeaddrinfo";

   --  WSABUF
   type Send_Buffer is record
      Length : unsigned_long;
      Base   : System.Address;
   end record with Convention => C;

   function C_WSASend
     (Socket     : Socket_Handle;
      Buffers    : System.Address;
      Count      : unsigned_long;
      Sent       : access unsigned_long;
      Flags      : unsigned_long;
      Overlapped : System.Address;
      Completion : System.Address) return int
      with Import, Convention => Stdcall, External_Name => "WSASend";

   AF_UNSPEC      : constant := 0;
   AF_INET6       : constant := 23;
   IPPROTO_IPV6   : constant := 41;
   IPV6_V6ONLY    : constant := 27;
   Storage_Layout : constant Socket_Storage.Layout := (Inet6_Family => AF_INET6, Length_Byte => False);

   --  A socket address as Winsock takes it.
   type Raw_Address is record
      Bytes  : aliased Socket_Storage.Storage := [others => 0];
      Length : aliased int := Socket_Storage.Storage'Length;
   end record;
   for Raw_Address'Alignment use 8;

   function To_Raw (Address : IP_Address; Port : Port_Number) return Raw_Address is
      Result : Raw_Address;
      Length : Positive;
   begin
      Socket_Storage.Encode (Address, Unsigned_16 (Port), Storage_Layout, Result.Bytes, Length);
      Result.Length := int (Length);
      return Result;
   end To_Raw;

   function Family_Code (Address : IP_Address) return int is
     (int (Socket_Storage.Family_Code (Address, Storage_Layout)));

   procedure Enable (Socket : Socket_Handle; Level, Name : int) is
      Enabled : aliased int := 1;
   begin
      if C_Setsockopt (Socket, Level, Name, Enabled'Address, int'Size / 8) /= 0 then
         null;   --  an option refused only costs performance
      end if;
   end Enable;

   procedure Close_Quietly (Socket : Socket_Handle) is begin
      if C_Closesocket (Socket) /= 0 then
         null;
      end if;
   end Close_Quietly;

   function Failed return Error is
      Result : Error := Last_Failure;
   begin
      if Result.Kind = None then
         Result.Kind := Other;
      end if;
      return Result;
   end Failed;

   procedure Resolve_All (Host : String; Addresses : out Address_List; Count : out Natural) is
      use type System.Address;
      Hints     : aliased Address_Info := (Family => AF_UNSPEC, Socket_Type => SOCK_STREAM, others => <>);
      Result    : aliased Address_Info_Access;
      Entry_Now : Address_Info_Access;
      Found     : Boolean;
   begin
      Addresses := [others => Loopback];
      Count     := 0;
      Parse_Address (Host, Addresses (Addresses'First), Found);
      if Found then
         Count := 1;
         return;
      elsif Host'Length = 0 or else (for some Symbol of Host => Symbol = ASCII.NUL) then
         return;
      end if;

      if C_Getaddrinfo (To_C (Host), System.Null_Address, Hints'Address, Result'Access) /= 0 or else Result = null
      then
         return;
      end if;

      Entry_Now := Result;
      while Entry_Now /= null and then Count < Addresses'Length loop
         if Entry_Now.Address /= System.Null_Address
           and then Entry_Now.Address_Length in 16 .. Socket_Storage.Storage'Length
         then
            declare
               Given   : Byte_Array (1 .. Natural (Entry_Now.Address_Length))
                  with Import, Address => Entry_Now.Address;
               Where   : Socket_Storage.Storage := [others => 0];
               Port    : Unsigned_16;
               Decoded : IP_Address;
            begin
               Where (Given'Range) := Given;
               Socket_Storage.Decode (Where, Storage_Layout, Decoded, Port, Found);
               --  The system lists an address once per protocol it serves: keep each once.
               if Found and then (for all Index in 1 .. Count => Addresses (Addresses'First - 1 + Index) /= Decoded)
               then
                  Count                                   := Count + 1;
                  Addresses (Addresses'First - 1 + Count) := Decoded;
               end if;
            end;
         end if;
         Entry_Now := Entry_Now.Next;
      end loop;
      C_Freeaddrinfo (Result);
   end Resolve_All;

   procedure Resolve (Host : String; Address : out IP_Address; Found : out Boolean) is
      First : Address_List (1 .. 1);
      Count : Natural;
   begin
      Resolve_All (Host, First, Count);
      Address := First (1);
      Found   := Count = 1;
   end Resolve;

   --  Windows has no option that spreads one port's connections over several listeners.
   function Shares_Ports return Boolean is (False);

   procedure Open_Listener
     (Address    : IP_Address;
      Port       : Port_Number;
      Listener   : out Descriptor;
      Failure    : out Error;
      Share_Port : Boolean := True;
      Backlog    : Positive := 4096)
   is
      Socket : constant Socket_Handle := C_Socket (Family_Code (Address), SOCK_STREAM, 0);
      Where  : aliased Raw_Address := To_Raw (Address, Port);
   begin
      Listener := No_Descriptor;
      if Socket = Invalid_Socket then
         Failure := Failed;
         if Address = Any_IPv6 then   --  no IPv6 here: every IPv4 interface, then
            Open_Listener (Any_IPv4, Port, Listener, Failure, Share_Port, Backlog);
         end if;
         return;
      end if;

      Enable (Socket, SOL_SOCKET, SO_EXCLUSIVEADDRUSE);
      if Address = Any_IPv6 then   --  dual stack: Windows makes IPv6 sockets IPv6-only unless told otherwise
         declare
            Off : aliased int := 0;
         begin
            if C_Setsockopt (Socket, IPPROTO_IPV6, IPV6_V6ONLY, Off'Address, Off'Size / 8) /= 0 then
               null;
            end if;
         end;
      end if;
      if not Set_Non_Blocking (Socket)
        or else C_Bind (Socket, Where.Bytes'Address, Where.Length) /= 0
        or else C_Listen (Socket, int (Integer'Min (Backlog, 65_535))) /= 0
      then
         Failure := Failed;
         Close_Quietly (Socket);
         return;
      end if;

      Listener := To_Descriptor (Socket);
      Failure  := No_Error;
   end Open_Listener;

   procedure Accept_Client
     (Listener : Descriptor; Socket : out Descriptor; Peer : out IP_Address; Failure : out Error)
   is
      Where    : aliased Raw_Address;
      Accepted : constant Socket_Handle := C_Accept (To_Handle (Listener), Where.Bytes'Address, Where.Length'Address);
   begin
      Socket := No_Descriptor;
      Peer   := Any_IPv4;
      if Accepted = Invalid_Socket then
         Failure := Failed;
      elsif not Set_Non_Blocking (Accepted) then   --  accepted sockets inherit it; this makes sure
         Failure := Failed;
         Close_Quietly (Accepted);
      else
         Enable (Accepted, IPPROTO_TCP, TCP_NODELAY);
         Socket  := To_Descriptor (Accepted);
         Failure := No_Error;
         declare
            Port  : Unsigned_16;
            Known : Boolean;
         begin
            Socket_Storage.Decode (Where.Bytes, Storage_Layout, Peer, Port, Known);
            Peer := (if Known then Unmapped (Peer) else Any_IPv4);
         end;
      end if;
   end Accept_Client;

   procedure Accept_Client (Listener : Descriptor; Socket : out Descriptor; Failure : out Error) is
      Peer : IP_Address;
   begin
      Accept_Client (Listener, Socket, Peer, Failure);
   end Accept_Client;

   procedure Bound_Waits (Socket : Socket_Handle; Timeout : Milliseconds) is
      Bound : aliased unsigned_long := unsigned_long (Timeout);   --  a DWORD of milliseconds
   begin
      if C_Setsockopt (Socket, SOL_SOCKET, SO_RCVTIMEO, Bound'Address, Bound'Size / 8) /= 0
        or else C_Setsockopt (Socket, SOL_SOCKET, SO_SNDTIMEO, Bound'Address, Bound'Size / 8) /= 0
      then
         null;   --  unbounded waits, then (Winsock's connect is bounded by its own retries)
      end if;
   end Bound_Waits;

   procedure Set_Timeout (Socket : Descriptor; Timeout : Milliseconds) is begin
      Bound_Waits (To_Handle (Socket), Timeout);
   end Set_Timeout;

   procedure Connect
     (Address : IP_Address;
      Port    : Port_Number;
      Socket  : out Descriptor;
      Failure : out Error;
      Timeout : Milliseconds := 0)
   is
      Opened : constant Socket_Handle := C_Socket (Family_Code (Address), SOCK_STREAM, 0);
      Where  : aliased Raw_Address := To_Raw (Address, Port);
   begin
      Socket := No_Descriptor;
      if Opened = Invalid_Socket then
         Failure := Failed;
         return;
      end if;

      if Timeout > 0 then
         Bound_Waits (Opened, Timeout);
      end if;

      if C_Connect (Opened, Where.Bytes'Address, Where.Length) /= 0 then
         Failure := Failed;
         Close_Quietly (Opened);
         return;
      end if;

      Enable (Opened, IPPROTO_TCP, TCP_NODELAY);
      Socket  := To_Descriptor (Opened);
      Failure := No_Error;
   end Connect;

   procedure Report (Got : Long_Long_Integer; Limit : Natural; Count : out Integer; Failure : out Error) is begin
      if Got < 0 or else Got > Long_Long_Integer (Limit) then
         Count   := -1;
         Failure := Failed;
      else
         Count   := Integer (Got);
         Failure := No_Error;
      end if;
   end Report;

   --  Winsock lengths are ints: at most this much goes in one call.
   Max_Chunk : constant := 2 ** 30;

   procedure Receive (Socket : Descriptor; Into : in out String; Count : out Integer; Failure : out Error) is
      Length : constant Natural := Natural'Min (Into'Length, Max_Chunk);
   begin
      Report (Long_Long_Integer (C_Recv (To_Handle (Socket), Into (Into'First)'Address, int (Length), 0)),
              Length, Count, Failure);
   end Receive;

   procedure Send (Socket : Descriptor; From : String; Count : out Integer; Failure : out Error) is
      Length : constant Natural := Natural'Min (From'Length, Max_Chunk);
   begin
      Report (Long_Long_Integer (C_Send (To_Handle (Socket), From (From'First)'Address, int (Length), 0)),
              Length, Count, Failure);
   end Send;

   procedure Send_Pair (Socket : Descriptor; Head, Content : String; Count : out Integer; Failure : out Error) is
      Buffers : aliased array (1 .. 2) of Send_Buffer :=
        [(unsigned_long (Natural'Min (Head'Length, Max_Chunk)), Head (Head'First)'Address),
         (unsigned_long (Natural'Min (Content'Length, Max_Chunk)),
          (if Content'Length = 0 then System.Null_Address else Content (Content'First)'Address))];
      Sent    : aliased unsigned_long := 0;
      Result  : constant int :=
        C_WSASend (To_Handle (Socket), Buffers'Address, (if Content'Length = 0 then 1 else 2), Sent'Access, 0,
                   System.Null_Address, System.Null_Address);
   begin
      Report ((if Result = Socket_Error then -1 else Long_Long_Integer (Sent)), Head'Length + Content'Length,
              Count, Failure);
   end Send_Pair;

end Sparrow.IO.Sockets;
