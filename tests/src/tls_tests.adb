with Checks; use Checks;
with Sparrow.IO; use Sparrow.IO;
with Sparrow.IO.Process;
with Sparrow.IO.Sockets; use Sparrow.IO.Sockets;
with Sparrow.Tls; use Sparrow.Tls;

--  A TLS server on a non-blocking socket in one task, a client on a blocking socket in the other.
procedure Tls_Tests is
   Port : constant Port_Number := 18_474;

   Server_Side : aliased Context;
   Listener    : Descriptor;
   Failure     : Error;
   Ready       : Boolean;

   --  Echoes what it receives, upper-cased, until the client ends the session. A real server waits for
   --  socket events where this one naps.
   task Server is
      entry Serve;
      entry Finished (Clean : out Boolean);
   end Server;

   task body Server is
      Socket  : Descriptor := No_Descriptor;
      Channel : Session;
      Result  : Outcome;
      Bytes   : String (1 .. 256);
      Count, Sent : Natural;
      Clean   : Boolean := False;
      Problem : Error;
   begin
      loop
         select
            accept Serve;
         or
            accept Finished (Clean : out Boolean) do
               Clean := Server.Clean;
            end Finished;
            exit;
         or
            terminate;
         end select;

         Clean := False;
         loop
            Accept_Client (Listener, Socket, Problem);
            exit when Socket /= No_Descriptor;
            Process.Sleep (2);
         end loop;

         Start_Server (Channel, Server_Side, Socket_Handle (Socket));
         loop
            Handshake (Channel, Result);
            exit when Result not in Want_Read | Want_Write;
            Process.Sleep (2);
         end loop;

         while Result = Done loop
            Receive (Channel, Bytes, Count, Result);
            if Result in Want_Read | Want_Write then
               Process.Sleep (2);
               Result := Done;
            elsif Result = Done then
               for Symbol of Bytes (1 .. Count) loop
                  if Symbol in 'a' .. 'z' then
                     Symbol := Character'Val (Character'Pos (Symbol) - 32);
                  end if;
               end loop;
               Send (Channel, Bytes (1 .. Count), Sent, Result);
            end if;
         end loop;

         Clean := Result = Closed;
         Free (Channel);
         Close (Socket);
      end loop;
   end Server;

   --  One client conversation; Greeting comes back upper-cased when the handshake succeeds.
   procedure Converse (Using : Context; Host : String; Expect_Success : Boolean; Name : String) is
      Socket  : Descriptor;
      Channel : Session;
      Result  : Outcome;
      Bytes   : String (1 .. 64);
      Count   : Natural;
      Clean   : Boolean;
      pragma Unreferenced (Clean);
   begin
      Server.Serve;
      Connect (Loopback, Port, Socket, Failure, Timeout => 5000);
      Check (Succeeded (Failure), Name & ": connect");
      Start_Client (Channel, Using, Socket_Handle (Socket), Host);
      Handshake (Channel, Result);
      Check ((Result = Done) = Expect_Success,
             Name & (if Expect_Success then ": handshake succeeds" else ": handshake fails"));

      if Result = Done then
         Check (Negotiated_Version (Channel) = Tls_1_3, Name & ": TLS 1.3");
         Send (Channel, "hello tls", Count, Result);
         Check (Result = Done and then Count = 9, Name & ": send");
         Receive (Channel, Bytes, Count, Result);
         Check (Result = Done and then Bytes (1 .. Count) = "HELLO TLS", Name & ": echo");
         Shut_Down (Channel, Result);
      else
         Check (Last_Failure (Channel)'Length > 0, Name & ": the failure is described");
      end if;

      Free (Channel);
      Close (Socket);
   end Converse;

   Trusting, Strict_System, Careless, Missing : Context;
   Clean : Boolean;
begin
   Process.Prepare_Networking (Ready);

   Open_Server (Missing, "data/no-such-cert.pem", "data/key.pem");
   Check (not Is_Open (Missing) and then Last_Failure (Missing)'Length > 0, "a missing certificate is reported");

   Open_Server (Server_Side, "data/cert.pem", "data/key.pem");
   Check (Is_Open (Server_Side), "server context: " & Last_Failure (Server_Side));
   Open_Client (Trusting, Verify => Full, Trust_File => "data/cert.pem");
   Check (Is_Open (Trusting), "client context trusting the test certificate");
   Open_Client (Strict_System, Verify => Full);
   Check (Is_Open (Strict_System), "client context with the system's roots");
   Open_Client (Careless, Verify => Nothing);
   Check (Is_Open (Careless), "client context that verifies nothing");

   Open_Listener (Loopback, Port, Listener, Failure);
   Check (Succeeded (Failure), "listener");

   if Is_Open (Server_Side) and then Succeeded (Failure) then
      Converse (Trusting, "localhost", True, "trusted root, right host");
      Converse (Trusting, "example.com", False, "trusted root, wrong host");
      Converse (Trusting, "", False, "full verification without a host name");
      Converse (Strict_System, "localhost", False, "self-signed against the system roots");
      Converse (Careless, "localhost", True, "no verification");
   end if;

   Server.Finished (Clean);
   Check (Clean, "the server saw the last session end cleanly");

   Close (Listener);
   Close (Trusting);
   Close (Strict_System);
   Close (Careless);
   Close (Server_Side);
   Finish ("tls");
end Tls_Tests;
