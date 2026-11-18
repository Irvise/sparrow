--  TCP sockets over IPv4 and IPv6: listeners, blocking client connections, and the reads and writes both use.
--
--  SPARK spec, system-call bodies (see Sparrow.IO).
with Sparrow.IO.Addresses;
with Sparrow.Times; use Sparrow.Times;

package Sparrow.IO.Sockets with SPARK_Mode is

   --  Addresses (Sparrow.IO.Addresses), named here too so that users of sockets need only this package.
   subtype IP_Address is Addresses.IP_Address;
   subtype Address_Family is Addresses.Address_Family;
   function Version_4 return Address_Family renames Addresses.Version_4;
   function Version_6 return Address_Family renames Addresses.Version_6;
   function "=" (Left, Right : IP_Address) return Boolean renames Addresses."=";
   function "=" (Left, Right : Address_Family) return Boolean renames Addresses."=";

   Any_IPv4      : IP_Address renames Addresses.Any_IPv4;
   Any_IPv6      : IP_Address renames Addresses.Any_IPv6;
   Loopback      : IP_Address renames Addresses.Loopback;
   Loopback_IPv6 : IP_Address renames Addresses.Loopback_IPv6;

   procedure Parse_Address (Text : String; Address : out IP_Address; Valid : out Boolean)
      renames Addresses.Parse_Address;
   function Image (Address : IP_Address) return String renames Addresses.Image;
   function Family_Of (Address : IP_Address) return Address_Family renames Addresses.Family_Of;

   type Port_Number is range 0 .. 65_535;

   --  An address, or a host name looked up for either family, the system's preferred answer first (this may
   --  block on DNS; call it at start-up or on a worker).
   procedure Resolve (Host : String; Address : out IP_Address; Found : out Boolean)
      with Global => (In_Out => Kernel), Pre => Host'Length in 1 .. 255;

   type Address_List is array (Positive range <>) of IP_Address;

   --  Every address Host stands for (as many as Addresses holds), the system's preferred first; Count is 0 when
   --  it stands for none. A client tries them in turn, so that "localhost" reaches a server on 127.0.0.1 as
   --  well as one on ::1.
   procedure Resolve_All (Host : String; Addresses : out Address_List; Count : out Natural)
      with Global => (In_Out => Kernel),
           Pre    => Host'Length in 1 .. 255 and then Addresses'Length > 0,
           Post   => Count <= Addresses'Length;

   ---------------------------------------------------------------------------------------------------------------
   --  servers

   --  Whether several listeners on one port have connections spread over them by the system (Linux). Where
   --  they do, a server opens one listener per reactor; elsewhere it opens one and every reactor watches it.
   function Shares_Ports return Boolean with Global => null;

   --  A non-blocking listening socket, or No_Descriptor with Failure. Share_Port asks for the sharing above
   --  and is ignored where there is none. On Any_IPv6 the listener takes clients of both families (dual stack);
   --  where the system has no IPv6, it falls back to Any_IPv4.
   procedure Open_Listener
     (Address    : IP_Address;
      Port       : Port_Number;
      Listener   : out Descriptor;
      Failure    : out Error;
      Share_Port : Boolean := True;
      Backlog    : Positive := 4096)
      with Global => (In_Out => Kernel),
           Post   => (Listener = No_Descriptor) = (not Succeeded (Failure));

   --  A non-blocking accept: the new connection (itself non-blocking, with Nagle's algorithm off), or
   --  No_Descriptor with Failure (Would_Block when no connection is waiting, which is also what a reactor
   --  sees when another one took the connection first).
   procedure Accept_Client (Listener : Descriptor; Socket : out Descriptor; Failure : out Error)
      with Global => (In_Out => Kernel),
           Post   => (Socket = No_Descriptor) = (not Succeeded (Failure));

   --  The same, also telling the client's address. An IPv4 client of a dual-stack listener is reported as
   --  IPv4 ("192.0.2.1", not "::ffff:192.0.2.1").
   procedure Accept_Client
     (Listener : Descriptor; Socket : out Descriptor; Peer : out IP_Address; Failure : out Error)
      with Global => (In_Out => Kernel),
           Post   => (Socket = No_Descriptor) = (not Succeeded (Failure));

   ---------------------------------------------------------------------------------------------------------------
   --  clients

   --  A blocking TCP connection with Nagle's algorithm off, or No_Descriptor with Failure. Timeout bounds the
   --  connect and every later read and write on the socket (0: no bound).
   procedure Connect
     (Address : IP_Address;
      Port    : Port_Number;
      Socket  : out Descriptor;
      Failure : out Error;
      Timeout : Milliseconds := 0)
      with Global => (In_Out => Kernel),
           Pre    => Timeout in 0 .. 3_600_000,
           Post   => (Socket = No_Descriptor) = (not Succeeded (Failure));

   --  Bound every later read and write on a blocking Socket by Timeout (0: no bound). A read or write that
   --  runs out of time fails with Would_Block.
   procedure Set_Timeout (Socket : Descriptor; Timeout : Milliseconds)
      with Global => (In_Out => Kernel), Pre => Timeout in 0 .. 3_600_000;

   ---------------------------------------------------------------------------------------------------------------
   --  Reads and writes. None of them raises a signal for a closed peer.

   --  A read into Into (Into'First .. Into'First + Count - 1). Count is 0 at end of stream, and -1 on a
   --  failure, which Failure then describes (Would_Block on a non-blocking socket with nothing to read).
   procedure Receive (Socket : Descriptor; Into : in out String; Count : out Integer; Failure : out Error)
      with Global => (In_Out => Kernel),
           Pre    => Into'Length > 0,
           Post   => Count in -1 .. Into'Length and then (Count >= 0) = Succeeded (Failure);

   --  A send of a prefix of From: Count bytes, or -1 with Failure.
   procedure Send (Socket : Descriptor; From : String; Count : out Integer; Failure : out Error)
      with Global => (In_Out => Kernel),
           Pre    => From'Length > 0,
           Post   => Count in -1 .. From'Length and then (Count >= 0) = Succeeded (Failure);

   --  One gathered send of Head then Content (a response's head and its body).
   procedure Send_Pair (Socket : Descriptor; Head, Content : String; Count : out Integer; Failure : out Error)
      with Global => (In_Out => Kernel),
           Pre    => Head'Length > 0 and then Content'Length <= Integer'Last - Head'Length,
           Post   => Count in -1 .. Head'Length + Content'Length and then (Count >= 0) = Succeeded (Failure);

end Sparrow.IO.Sockets;
