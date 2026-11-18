--  TLS 1.2 and 1.3 for a connected socket, on either side: a narrow binding to OpenSSL's libssl (3.0 or
--  later). Nothing of the library shows in this spec.

--  A Session works on blocking and non-blocking sockets alike. On a non-blocking one, every operation may
--  report Want_Read or Want_Write: wait for that event on the socket, then make the same call again.
--
--  The library writes to the socket itself: prepare the process for sockets first (on POSIX, a closed peer
--  must not raise SIGPIPE).
--
--  SPARK spec, so proved code can call it; the bodies are outside SPARK. Nothing here raises.
private with System;

--  Network: the sockets the library reads and writes, which other tasks and the system change.
package Sparrow.Tls
  with SPARK_Mode, Abstract_State => (Network with Synchronous, External), Initializes => Network
is

   --  A connected socket as the system numbers it: a file descriptor, or a socket handle on Windows.
   type Socket_Handle is range -1 .. 2 ** 63 - 1;

   type Protocol_Version is (Tls_1_2, Tls_1_3);

   ---------------------------------------------------------------------------------------------------------------
   --  A Context is one side's configuration: its certificate, or whom it trusts. Open it at start-up; after
   --  that it only hands out sessions, and tasks may share it.

   type Context is limited private;

   function Is_Open (This : Context) return Boolean;

   --  A server's context. Certificate_File holds the certificate followed by any intermediates, Key_File its
   --  private key, both PEM. Offer_Http_2: let clients choose HTTP/2 ("h2") over HTTP/1.1 by ALPN.
   procedure Open_Server
     (This             : in out Context;
      Certificate_File : String;
      Key_File         : String;
      Minimum_Version  : Protocol_Version := Tls_1_2;
      Offer_Http_2     : Boolean := True)
      with Global => (In_Out => Network), Pre => not Is_Open (This);

   --  What a client demands of the server's certificate.
   type Verification is
     (Full,          --  a chain to a trusted root, and the certificate names the host asked for
      Chain_Only,    --  a chain to a trusted root, whatever host it names
      Nothing);      --  encryption without authentication: anyone can sit in the middle

   --  A client's context. Trust_File is a PEM file of root certificates; "" uses the system's own store.
   procedure Open_Client
     (This            : in out Context;
      Verify          : Verification := Full;
      Trust_File      : String := "";
      Minimum_Version : Protocol_Version := Tls_1_2)
      with Global => (In_Out => Network), Pre => not Is_Open (This);

   procedure Close (This : in out Context)
      with Global => (In_Out => Network), Post => not Is_Open (This);

   --  Why the last Open of This failed ("" when it did not), for the log.
   function Last_Failure (This : Context) return String
      with Post => Last_Failure'Result'Length <= 200;

   ---------------------------------------------------------------------------------------------------------------
   --  A Session is one connection's TLS state. It belongs to one task at a time.

   type Session is limited private;

   function Is_Active (This : Session) return Boolean;

   type Outcome is
     (Done,
      Want_Read,     --  wait until the socket is readable, then call again
      Want_Write,    --  wait until the socket is writable, then call again
      Closed,        --  the peer ended the session
      Failed);       --  see Last_Failure; the session is of no more use

   --  Begin a session over Socket, which stays the caller's to close. Host_Name is the server the client
   --  means to reach: sent to it (SNI) and checked against its certificate under Full.
   procedure Start_Server (This : in out Session; Using : Context; Socket : Socket_Handle)
      with Global => (In_Out => Network), Pre => Is_Open (Using) and then not Is_Active (This);

   procedure Start_Client (This : in out Session; Using : Context; Socket : Socket_Handle; Host_Name : String)
      with Global => (In_Out => Network),
           Pre    => Is_Open (Using) and then not Is_Active (This) and then Host_Name'Length <= 255;

   --  Carry the handshake on; call it until Done before the first Receive or Send.
   procedure Handshake (This : in out Session; Result : out Outcome)
      with Global => (In_Out => Network);

   --  Decrypted bytes into Into (Into'First .. Into'First + Count - 1). Count is 0 unless Result is Done.
   procedure Receive (This : in out Session; Into : in out String; Count : out Natural; Result : out Outcome)
      with Global => (In_Out => Network),
           Pre    => Into'Length > 0,
           Post   => Count <= Into'Length and then (if Result /= Done then Count = 0);

   --  Whether decrypted bytes are waiting inside the session. The socket will not announce those: after an
   --  event, Receive until Want_Read, not merely until the socket runs dry.
   function Has_Pending (This : Session) return Boolean;

   --  Encrypt and send a prefix of From: Count bytes. After Want_Read or Want_Write, call again with the
   --  same bytes.
   procedure Send (This : in out Session; From : String; Count : out Natural; Result : out Outcome)
      with Global => (In_Out => Network),
           Pre    => From'Length > 0,
           Post   => Count <= From'Length and then (if Result /= Done then Count = 0);

   --  Tell the peer the session is ending (close_notify).
   procedure Shut_Down (This : in out Session; Result : out Outcome)
      with Global => (In_Out => Network);

   --  Release the session's storage; the socket is untouched.
   procedure Free (This : in out Session)
      with Global => (In_Out => Network), Post => not Is_Active (This);

   function Negotiated_Version (This : Session) return Protocol_Version with Pre => Is_Active (This);

   --  The application protocol the handshake chose by ALPN ("h2", "http/1.1"), "" when none.
   function Negotiated_Protocol (This : Session) return String
      with Pre => Is_Active (This), Post => Negotiated_Protocol'Result'Length <= 255;

   --  Why the session Failed, for the log.
   function Last_Failure (This : Session) return String
      with Post => Last_Failure'Result'Length <= 200;

private
   pragma SPARK_Mode (Off);

   subtype Failure_Text is String (1 .. 200);

   type Context is limited record
      Handle         : System.Address := System.Null_Address;   --  the library's own object
      Verify         : Verification := Full;
      Failure        : Failure_Text := [others => ' '];
      Failure_Length : Natural range 0 .. 200 := 0;
   end record;

   type Session is limited record
      Handle         : System.Address := System.Null_Address;
      Failure        : Failure_Text := [others => ' '];
      Failure_Length : Natural range 0 .. 200 := 0;
   end record;

   use type System.Address;

   function Is_Open (This : Context) return Boolean is (This.Handle /= System.Null_Address);
   function Is_Active (This : Session) return Boolean is (This.Handle /= System.Null_Address);

end Sparrow.Tls;
