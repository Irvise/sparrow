--  Sockets over the POSIX calls; what differs between systems is in Sparrow.IO.Platform.
with Interfaces; use Interfaces;
with Interfaces.C; use Interfaces.C;
with Sparrow.IO.Platform; use Sparrow.IO.Platform;
with Sparrow.IO.Addresses; use Sparrow.IO.Addresses;
with Sparrow.IO.Posix; use Sparrow.IO.Posix;
with Sparrow.IO.Socket_Storage;
with System;

package body Sparrow.IO.Sockets with SPARK_Mode => Off is

   AF_UNSPEC    : constant := 0;
   SOCK_STREAM  : constant := 1;
   IPPROTO_TCP  : constant := 6;
   TCP_NODELAY  : constant := 1;
   IPPROTO_IPV6 : constant := 41;

   function C_Socket (Domain, Kind, Protocol : int) return int
      with Import, Convention => C, External_Name => "socket";
   function C_Setsockopt (Socket : int; Level, Name : int; Value : System.Address; Length : unsigned) return int
      with Import, Convention => C, External_Name => "setsockopt";
   function C_Bind (Socket : int; Address : System.Address; Length : unsigned) return int
      with Import, Convention => C, External_Name => "bind";
   function C_Listen (Socket : int; Backlog : int) return int
      with Import, Convention => C, External_Name => "listen";
   function C_Accept (Socket : int; Address, Length : System.Address) return int
      with Import, Convention => C, External_Name => "accept";
   function C_Connect (Socket : int; Address : System.Address; Length : unsigned) return int
      with Import, Convention => C, External_Name => "connect";

   --  struct iovec, the same everywhere
   type IO_Vector is record
      Base   : System.Address;
      Length : size_t;
   end record with Convention => C;

   function C_Writev (Socket : int; Vectors : System.Address; Count : int) return long
      with Import, Convention => C, External_Name => "writev";

   function C_Getaddrinfo
     (Node : char_array; Service : System.Address; Hints : System.Address; Result : access Address_Info_Access)
      return int
      with Import, Convention => C, External_Name => "getaddrinfo";
   procedure C_Freeaddrinfo (Result : Address_Info_Access)
      with Import, Convention => C, External_Name => "freeaddrinfo";

   --  A socket address as the system takes it.
   type Raw_Address is record
      Bytes  : aliased Socket_Storage.Storage := [others => 0];
      Length : aliased unsigned := Socket_Storage.Storage'Length;
   end record;
   for Raw_Address'Alignment use 8;

   function To_Raw (Address : IP_Address; Port : Port_Number) return Raw_Address is
      Result : Raw_Address;
      Length : Positive;
   begin
      Socket_Storage.Encode (Address, Unsigned_16 (Port), Storage_Layout, Result.Bytes, Length);
      Result.Length := unsigned (Length);
      return Result;
   end To_Raw;

   function Family_Code (Address : IP_Address) return int is
     (int (Socket_Storage.Family_Code (Address, Storage_Layout)));

   --  An option the kernel refuses only costs performance.
   procedure Enable (Socket : int; Level, Name : int) is
      Enabled : aliased int := 1;
   begin
      if C_Setsockopt (Socket, Level, Name, Enabled'Address, unsigned (int'Size / 8)) /= 0 then
         null;
      end if;
   end Enable;

   procedure Close_Quietly (Socket : int) is begin
      if C_Close (Socket) /= 0 then
         null;   --  the descriptor is released even when close reports an error
      end if;
   end Close_Quietly;

   --  A failure that is never None: an error reported with errno 0 is still an error.
   function Failed return Error is
      Result : Error := Last_Failure;
   begin
      if Result.Kind = None then
         Result.Kind := Other;
      end if;
      return Result;
   end Failed;

   -------------
   -- Resolve --
   -------------

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

   function Shares_Ports return Boolean is (Balances_Ports);

   -------------------
   -- Open_Listener --
   -------------------

   procedure Open_Listener
     (Address    : IP_Address;
      Port       : Port_Number;
      Listener   : out Descriptor;
      Failure    : out Error;
      Share_Port : Boolean := True;
      Backlog    : Positive := 4096)
   is
      Socket : constant int := C_Socket (Family_Code (Address), SOCK_STREAM, 0);
      Where  : aliased Raw_Address := To_Raw (Address, Port);
   begin
      Listener := No_Descriptor;
      if Socket < 0 then
         Failure := Failed;
         if Address = Any_IPv6 then   --  no IPv6 here: every IPv4 interface, then
            Open_Listener (Any_IPv4, Port, Listener, Failure, Share_Port, Backlog);
         end if;
         return;
      end if;

      Enable (Socket, SOL_SOCKET, SO_REUSEADDR);
      if Share_Port and then Balances_Ports then
         Enable (Socket, SOL_SOCKET, SO_SHARE_PORT);
      end if;
      if Address = Any_IPv6 then   --  dual stack: IPv4 clients too, whatever the system's default
         declare
            Off : aliased int := 0;
         begin
            if C_Setsockopt (Socket, IPPROTO_IPV6, IPV6_V6ONLY, Off'Address, unsigned (int'Size / 8)) /= 0 then
               null;   --  then IPv6 clients only
            end if;
         end;
      end if;

      if not Prepare_Descriptor (Socket, Non_Blocking => True)
        or else C_Bind (Socket, Where.Bytes'Address, Where.Length) /= 0
        or else C_Listen (Socket, int (Integer'Min (Backlog, 65_535))) /= 0
      then
         Failure := Failed;
         Close_Quietly (Socket);
         return;
      end if;

      Listener := Descriptor (Socket);
      Failure  := No_Error;
   end Open_Listener;

   -------------------
   -- Accept_Client --
   -------------------

   procedure Accept_Client
     (Listener : Descriptor; Socket : out Descriptor; Peer : out IP_Address; Failure : out Error)
   is
      Where    : aliased Raw_Address;
      Accepted : constant int := C_Accept (int (Listener), Where.Bytes'Address, Where.Length'Address);
   begin
      Socket := No_Descriptor;
      Peer   := Any_IPv4;
      if Accepted < 0 then
         Failure := Failed;
      elsif not Prepare_Descriptor (Accepted, Non_Blocking => True) then
         Failure := Failed;
         Close_Quietly (Accepted);
      else
         Enable (Accepted, IPPROTO_TCP, TCP_NODELAY);
         Socket  := Descriptor (Accepted);
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

   -------------
   -- Connect --
   -------------

   --  struct timeval. macOS has a 32-bit tv_usec, but the field after it is padding and these platforms are
   --  little-endian, so writing 64 bits sets it alike.
   type Time_Value is record
      Seconds      : long;
      Microseconds : long;
   end record with Convention => C;

   procedure Bound_Waits (Socket : int; Timeout : Milliseconds) is
      Bound : aliased Time_Value := (long (Timeout / 1000), long (Timeout mod 1000) * 1000);
   begin
      if C_Setsockopt (Socket, SOL_SOCKET, SO_RCVTIMEO, Bound'Address, Time_Value'Size / 8) /= 0
        or else C_Setsockopt (Socket, SOL_SOCKET, SO_SNDTIMEO, Bound'Address, Time_Value'Size / 8) /= 0
      then
         null;   --  unbounded waits, then
      end if;
   end Bound_Waits;

   procedure Set_Timeout (Socket : Descriptor; Timeout : Milliseconds) is begin
      Bound_Waits (int (Socket), Timeout);
   end Set_Timeout;

   procedure Connect
     (Address : IP_Address;
      Port    : Port_Number;
      Socket  : out Descriptor;
      Failure : out Error;
      Timeout : Milliseconds := 0)
   is
      Opened : constant int := C_Socket (Family_Code (Address), SOCK_STREAM, 0);
      Where  : aliased Raw_Address := To_Raw (Address, Port);
   begin
      Socket := No_Descriptor;
      if Opened < 0 then
         Failure := Failed;
         return;
      elsif not Prepare_Descriptor (Opened, Non_Blocking => False) then
         Failure := Failed;
         Close_Quietly (Opened);
         return;
      end if;

      if Timeout > 0 then   --  the send bound also bounds connect
         Bound_Waits (Opened, Timeout);
      end if;

      if C_Connect (Opened, Where.Bytes'Address, Where.Length) /= 0 then
         Failure := Failed;
         Close_Quietly (Opened);
         return;
      end if;

      Enable (Opened, IPPROTO_TCP, TCP_NODELAY);
      Socket  := Descriptor (Opened);
      Failure := No_Error;
   end Connect;

   --  A count the kernel returned, as the specs promise it: within Limit, or -1 with the failure.
   procedure Report (Got : long; Limit : Natural; Count : out Integer; Failure : out Error) is begin
      if Got < 0 or else Got > long (Limit) then
         Count   := -1;
         Failure := Failed;
      else
         Count   := Integer (Got);
         Failure := No_Error;
      end if;
   end Report;

   procedure Receive (Socket : Descriptor; Into : in out String; Count : out Integer; Failure : out Error) is begin
      Report (C_Read (int (Socket), Into (Into'First)'Address, size_t (Into'Length)), Into'Length, Count, Failure);
   end Receive;

   procedure Send (Socket : Descriptor; From : String; Count : out Integer; Failure : out Error) is begin
      --  write, not send: SIGPIPE is ignored (Prepare_Networking), so no flag is needed to keep it away.
      Report (C_Write (int (Socket), From (From'First)'Address, size_t (From'Length)), From'Length, Count, Failure);
   end Send;

   procedure Send_Pair (Socket : Descriptor; Head, Content : String; Count : out Integer; Failure : out Error) is
      Vectors : aliased array (1 .. 2) of IO_Vector :=
        [(Head (Head'First)'Address, size_t (Head'Length)),
         ((if Content'Length = 0 then System.Null_Address else Content (Content'First)'Address),
          size_t (Content'Length))];
   begin
      Report (C_Writev (int (Socket), Vectors'Address, (if Content'Length = 0 then 1 else 2)),
              Head'Length + Content'Length, Count, Failure);
   end Send_Pair;

end Sparrow.IO.Sockets;
