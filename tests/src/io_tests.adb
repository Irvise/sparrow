with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Checks; use Checks;
with Log_Capture;
with Sparrow.Logs;
with Sparrow.IO; use Sparrow.IO;
with Sparrow.IO.Addresses;
with Sparrow.IO.Events; use Sparrow.IO.Events;
with Sparrow.IO.Process;
with Sparrow.IO.Sockets; use Sparrow.IO.Sockets;
with Sparrow.Times; use Sparrow.Times;

procedure IO_Tests is
   Port     : constant Port_Number := 18_473;
   Listener, Client, Served : Descriptor;
   Failure  : Error;
   Address  : IP_Address;
   Valid    : Boolean;
   Loop_One : Poller;
   Wake     : Waker;
   Found    : Event_Array (1 .. 8);
   Count    : Natural;
   Got      : Integer;
   Bytes    : String (1 .. 64);
   Ready    : Boolean;
   Now      : Unix_Seconds;
   Before, After : Milliseconds;

   function Seen (Item : Descriptor; Readable : Boolean := True) return Boolean is
     (for some Each of Found (1 .. Count) => Each.Item = Item and then Each.Readable = Readable);
begin
   Process.Prepare_Networking (Ready);
   Check (Ready, "networking ready");

   Parse_Address ("127.0.0.1", Address, Valid);
   Check (Valid and then Address = Loopback, "parse address");
   Parse_Address ("256.1.1.1", Address, Valid);
   Check (not Valid, "parse address out of range");
   Parse_Address ("1.2.3", Address, Valid);
   Check (not Valid, "parse address too short");
   Resolve ("localhost", Address, Valid);
   Check (Valid and then Address in Loopback | Loopback_IPv6, "resolve localhost");
   Resolve ("::1", Address, Valid);
   Check (Valid and then Address = Loopback_IPv6, "resolve an IPv6 literal");
   Resolve ("no-such-host.invalid", Address, Valid);
   Check (not Valid, "resolve unknown host");
   declare
      Every : Address_List (1 .. 8);
      Count : Natural;
   begin
      Resolve_All ("localhost", Every, Count);
      Check (Count in 1 .. 2 and then (for all Index in 1 .. Count => Every (Index) in Loopback | Loopback_IPv6)
             and then (Count = 1 or else Every (1) /= Every (2)), "resolve every address of localhost, once each");
      Resolve_All ("192.0.2.1", Every, Count);
      Check (Count = 1 and then Image (Every (1)) = "192.0.2.1", "resolve every address of a literal");
      Resolve_All ("no-such-host.invalid", Every, Count);
      Check (Count = 0, "resolve every address of an unknown host");
   end;

   Process.Read_Clock (Now);
   Check (Now > 1_700_000_000, "wall clock");
   Process.Read_Monotonic (Before);
   Process.Sleep (30);
   Process.Read_Monotonic (After);
   Check (After - Before in 20 .. 200, "monotonic clock and sleep");
   Check (Process.Environment ("SPARROW_NO_SUCH_VARIABLE", "fallback") = "fallback", "environment default");
   Check (Process.Environment ("PATH")'Length > 0, "environment value");

   Connect (Loopback, Port, Client, Failure);
   Check (Client = No_Descriptor and then Failure.Kind = Connection_Refused, "connect refused");
   Check (Message (Failure)'Length > 0, "failure message");

   Open_Listener (Loopback, Port, Listener, Failure);
   Check (Succeeded (Failure), "open listener");
   Accept_Client (Listener, Served, Failure);
   Check (Failure.Kind = Would_Block, "accept with nobody waiting");

   Open (Loop_One, Failure);
   Check (Succeeded (Failure) and then Is_Open (Loop_One), "open poller");
   Open (Wake, Failure);
   Check (Succeeded (Failure), "open waker");
   Watch (Loop_One, Listener);
   Watch (Loop_One, Watched_End (Wake));

   Wait (Loop_One, Found, 0, Count);
   Check (Count = 0, "nothing ready");

   Signal (Wake);
   Wait (Loop_One, Found, 1000, Count);
   Check (Count = 1 and then Seen (Watched_End (Wake)), "waker wakes");
   Drain (Wake);
   Wait (Loop_One, Found, 0, Count);
   Check (Count = 0, "waker drained");

   Connect (Loopback, Port, Client, Failure, Timeout => 2000);
   Check (Succeeded (Failure), "connect");
   Wait (Loop_One, Found, 1000, Count);
   Check (Seen (Listener), "listener readable");
   Accept_Client (Listener, Served, Failure);
   Check (Succeeded (Failure), "accept");
   Watch (Loop_One, Served, (Readable => True, Writable => True));
   Wait (Loop_One, Found, 1000, Count);
   Check ((for some Each of Found (1 .. Count) => Each.Item = Served and then Each.Writable), "new socket writable");

   Send (Client, "ping", Got, Failure);
   Check (Got = 4, "send");
   Wait (Loop_One, Found, 1000, Count);
   Check (Seen (Served), "served socket readable");
   Receive (Served, Bytes, Got, Failure);
   Check (Got = 4 and then Bytes (1 .. 4) = "ping", "receive");
   Receive (Served, Bytes, Got, Failure);
   Check (Got = -1 and then Failure.Kind = Would_Block, "receive would block");

   Send_Pair (Served, "head:", "content", Got, Failure);
   Check (Got = 12, "send pair");
   Receive (Client, Bytes, Got, Failure);
   Check (Got = 12 and then Bytes (1 .. 12) = "head:content", "receive pair");
   Send_Pair (Served, "only", "", Got, Failure);
   Check (Got = 4, "send pair with no content");
   Receive (Client, Bytes, Got, Failure);   --  left unread, closing would reset the connection

   Close (Client);
   Wait (Loop_One, Found, 1000, Count);
   Check ((for some Each of Found (1 .. Count) => Each.Item = Served and then Each.Closed), "peer close is seen");
   Receive (Served, Bytes, Got, Failure);
   Check (Got = 0, "end of stream");
   Send (Served, "x", Got, Failure);
   Send (Served, "x", Got, Failure);
   Check (Got = -1 and then Failure.Kind = Connection_Closed, "send to a closed peer is a value, not a signal");

   Unwatch (Loop_One, Served);
   Close (Served);
   Close (Listener);
   Close (Wake);
   Close (Loop_One);
   Check (not Is_Open (Loop_One) and then not Is_Open (Wake), "closed");

   --  Logs
   declare
      use Sparrow.Logs;
      function Has (Text, Part : String) return Boolean is (Ada.Strings.Fixed.Index (Text, Part) > 0);
      Text_Line : constant String :=
        Format_Line (Warning, "disk low", Field ("free_mb", 12) & Field ("mount", "/var lib") & Field ("ok", False)
                                          & Field ("ms", Duration (0.0125)));
   begin
      Check (Text_Line'Length > 25 and then Text_Line (5) = '-' and then Text_Line (24) = 'Z'
             and then Has (Text_Line, "Z WARNING disk low free_mb=12 mount=""/var lib"" ok=false ms=12.500"),
             "a text log line: time, level, message, fields");
      declare
         Forged : constant String := Format_Line (Info, "login", Field ("user", "bob" & ASCII.LF & "ERROR fake"));
      begin
         Check (not Has (Forged, [ASCII.LF]) and then Has (Forged, "user=""bob\nERROR fake"""),
                "a line break in a value cannot start a new line");
      end;
      Configure (Threshold => Info, Style => Json);
      declare
         Line : constant String :=
           Format_Line (Sparrow.Logs.Error, "say ""hi""",
                        Field ("n", -3) & Field ("bytes", "a" & Character'Val (16#FF#))
                        & Field ("name", "Zo" & Character'Val (16#C3#) & Character'Val (16#AB#)));
      begin
         Check (Line (1 .. 9) = "{""time"":""" and then Line (Line'Last) = '}', "a JSON log line: an object");
         Check (Has (Line, """level"":""error"",""message"":""say \""hi\"""",""n"":-3,"),
                "JSON: level, message, number");
         Check (Has (Line, """bytes"":""a\u00ff"""), "JSON: invalid UTF-8 escaped");
         Check (Has (Line, """name"":""Zo" & Character'Val (16#C3#) & Character'Val (16#AB#) & """"),
                "JSON: UTF-8 kept");
      end;
      Set_Sink (Log_Capture.Keep'Access);
      Debug ("not shown");
      Info ("shown", Field ("k", "v"), Field ("j", 2));
      Check (Log_Capture.Find ("not shown") = "" and then Has (Log_Capture.Find ("shown"), """k"":""v"",""j"":2}"),
             "levels below the threshold are dropped; a sink receives the rest");
      Configure (Threshold => Debug, Style => Text);
      Check (Enabled (Debug), "the threshold can be lowered");

      --  Lines built field by field.
      Configure (Threshold => Info, Style => Text);
      declare
         Line : Line_Builder (Capacity => 160);
      begin
         Start (Line, Info, "request");
         Add (Line, "path", "/a b");
         Add (Line, "status", 200);
         Add (Line, "ms", Duration (0.0125));
         Write (Line);
         Check (Has (Log_Capture.Find ("request"), "Z INFO    request path=""/a b"" status=200 ms=12.500"),
                "a built line: the same format as Log");
         Start (Line, Info, "cut");
         Add (Line, "big", [1 .. 100 => 'y']);   --  its worst case, escaped, does not fit
         Add (Line, "small", 1);
         Write (Line);
         Check (Has (Log_Capture.Find ("cut"), "cut small=1 truncated=true"), "a field that might not fit is left out");
         Start (Line, Debug, "quiet");
         Add (Line, "x", 1);
         Write (Line);
         Check (Log_Capture.Find ("quiet") = "", "a built line below the threshold is not written");
      end;
      Configure (Threshold => Info, Style => Json);
      declare
         Line : Line_Builder (Capacity => 512);
      begin
         Start (Line, Warning, "json built");
         Add (Line, "who", "a""b");
         Add (Line, "n", -4);
         Write (Line);
         Check (Has (Log_Capture.Find ("json built"), """message"":""json built"",""who"":""a\""b"",""n"":-4}"),
                "a built line in JSON");
      end;
      Set_Sink (null);
      Configure;
      Log_Capture.Clear;
   end;

   --  Batched output: log_writer's tasks write to standard error, read back here.
   declare
      use Ada.Strings.Fixed;
      Program : constant String := "bin/log_writer";

      --  Runs log_writer with standard error to a file; checks what it wrote.
      procedure Check_Output (Mode : String) is
         Output_File : constant String := "obj/log_writer_" & Mode & ".txt";
         Arguments   : GNAT.OS_Lib.Argument_List (1 .. 0);
         Success     : Boolean;
         Code        : Integer;
         File        : Ada.Text_IO.File_Type;
         Next        : array (1 .. 6) of Natural := [others => 1];
         In_Order    : Boolean := True;
         Whole       : Boolean := True;
         Long_Seen   : Boolean := False;
         Long_Placed : Boolean := False;
      begin
         GNAT.OS_Lib.Spawn (Program, Arguments, Output_File, Success, Code, Err_To_Out => True);
         Check (Success and then Code = 0, Mode & ": log_writer ran");
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Output_File);
         while not Ada.Text_IO.End_Of_File (File) loop
            declare
               Line   : constant String := Ada.Text_IO.Get_Line (File);
               Task_At : constant Natural := Index (Line, " task=");
               N_At    : constant Natural := Index (Line, " n=");
            begin
               if Index (Line, "Z INFO    long task=1 text=x") > 0 then
                  Long_Seen   := Line'Length = 24 + 1 + 8 + 4 + 7 + 6 + 20_000;
                  Long_Placed := Next (1) = 1001;
               elsif Index (Line, "Z INFO    line task=") > 0 and then Task_At > 0 and then N_At > Task_At then
                  declare
                     Writer : constant Positive := Positive'Value (Line (Task_At + 6 .. N_At - 1));
                     Number : constant Positive := Positive'Value (Line (N_At + 3 .. Line'Last));
                  begin
                     In_Order := In_Order and then Number = Next (Writer);
                     Next (Writer) := Number + 1;
                  end;
               else
                  Whole := False;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (File);
         Check (Whole, Mode & ": every line whole");
         Check (In_Order and then (for all Count of Next => Count = 2001),
                Mode & ": every line of every task, each task's in order, the last ones at exit");
         Check (Long_Seen and then Long_Placed, Mode & ": a long line whole, among its task's lines");
      end Check_Output;
   begin
      Check_Output ("buffered");
      Ada.Environment_Variables.Set ("LOG_BUFFER", "off");
      Check_Output ("unbuffered");
      Ada.Environment_Variables.Clear ("LOG_BUFFER");
   end;

   Check (Image (Sparrow.IO.Addresses.IPv4 (192, 168, 0, 1)) = "192.168.0.1" and then Image (Any_IPv4) = "0.0.0.0",
          "address images");

   --  IPv6 text: every form RFC 4291 allows is read, the RFC 5952 form is written.
   declare
      function Canonical (Text : String) return String is
         Parsed : IP_Address;
         Good   : Boolean;
      begin
         Parse_Address (Text, Parsed, Good);
         return (if Good then Image (Parsed) else "invalid");
      end Canonical;
   begin
      Check (Canonical ("::") = "::" and then Canonical ("::1") = "::1" and then Canonical ("1::") = "1::",
             "IPv6: the shortest forms");
      Check (Canonical ("2001:DB8:0:0:0:0:0:1") = "2001:db8::1", "IPv6: lower case, longest zero run compressed");
      Check (Canonical ("2001:db8:0:1:0:0:0:1") = "2001:db8:0:1::1", "IPv6: the longer zero run is the one compressed");
      Check (Canonical ("2001:db8:0:0:1:0:0:1") = "2001:db8::1:0:0:1", "IPv6: the first of two equal runs");
      Check (Canonical ("2001:db8:0:1:1:1:1:1") = "2001:db8:0:1:1:1:1:1",
             "IPv6: a single zero group is not compressed");
      Check (Canonical ("0001:0db8::00ff") = "1:db8::ff", "IPv6: leading zeros dropped");
      Check (Canonical ("::ffff:192.0.2.1") = "::ffff:192.0.2.1"
             and then Canonical ("64:ff9b::192.0.2.1") = "64:ff9b::c000:201", "IPv6: an embedded dotted quad");
      Check (Canonical ("[2001:db8::1]") = "2001:db8::1", "IPv6: brackets");
      Check (Canonical ("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff") = "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
             "IPv6: the longest image");
      for Bad in 1 .. 18 loop
         declare
            Text : constant String :=
              (case Bad is
                  when 1  => "1:2:3:4:5:6:7:8:9", when 2  => ":::",     when 3  => "1:::2",
                  when 4  => "1::2::3",           when 5  => "12345::", when 6  => "1:2:3:4:5:6:7",
                  when 7  => ":1::",              when 8  => "1::2:",   when 9  => "fe80::1%eth0",
                  when 10 => "[::1",              when 11 => "::1]",    when 12 => "[1.2.3.4]",
                  when 13 => "g::1",              when 14 => "::1.2.3", when 15 => "1:2:3:4:5:6:7:1.2.3.4",
                  when 16 => "01.2.3.4",          when 17 => "1.2.3.04", when others => "");
         begin
            Check (Canonical (Text) = "invalid", "malformed address refused: [" & Text & "]");
         end;
      end loop;
      Check (Canonical ("1:2:3:4:5:6:1.2.3.4") = "1:2:3:4:5:6:102:304", "IPv6: a full address ending in a quad");
      Parse_Address ("::ffff:10.1.2.3", Address, Valid);
      Check (Sparrow.IO.Addresses.Unmapped (Address) = Sparrow.IO.Addresses.IPv4 (10, 1, 2, 3)
             and then Sparrow.IO.Addresses.Unmapped (Loopback_IPv6) = Loopback_IPv6, "mapped IPv4 addresses");
      Check (Sparrow.IO.Addresses.Is_Any (Any_IPv6) and then not Sparrow.IO.Addresses.Is_Any (Loopback),
             "unspecified addresses");
   end;

   --  A dual-stack listener on :: takes clients of both families and reports an IPv4 client as IPv4.
   declare
      Both_Port : constant Port_Number := 18_478;
      Peer      : IP_Address;
   begin
      Open_Listener (Any_IPv6, Both_Port, Listener, Failure, Share_Port => False);
      Check (Succeeded (Failure), "open a dual-stack listener");
      Connect (Loopback_IPv6, Both_Port, Client, Failure, Timeout => 2000);
      Check (Succeeded (Failure), "connect over IPv6");
      Process.Sleep (20);
      Accept_Client (Listener, Served, Peer, Failure);
      Check (Succeeded (Failure) and then Peer = Loopback_IPv6, "an IPv6 client is seen as ::1");
      Close (Served);
      Close (Client);
      Connect (Loopback, Both_Port, Client, Failure, Timeout => 2000);
      Check (Succeeded (Failure), "connect over IPv4 to the dual-stack listener");
      Process.Sleep (20);
      Accept_Client (Listener, Served, Peer, Failure);
      Check (Succeeded (Failure) and then Peer = Loopback and then Image (Peer) = "127.0.0.1",
             "an IPv4 client of a dual-stack listener is seen as IPv4");
      Close (Served);
      Close (Client);
      Close (Listener);
   end;

   Finish ("io");
end IO_Tests;
