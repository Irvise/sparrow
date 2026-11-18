with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Sparrow.Buffers;
with Sparrow.Http.Bodies;
with Sparrow.Http.Event_Streams;
with Sparrow.Http.Log;
with Sparrow.Http.Multipart;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.IO.Process;
with Sparrow.Encoding;

package body Http_Test_Handlers is

   use Sparrow;

   procedure Hello (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Sparrow.Http.Responses.Send (Response, OK, "hello");
   end Hello;

   function Long_Text return String is
      Result : String (1 .. 20_000);
   begin
      for Index in Result'Range loop
         Result (Index) := (if Index mod 61 = 0 then ASCII.LF
                            else Character'Val (Character'Pos ('a') + (Index * Index / 7) mod 26));
      end loop;
      return Result;
   end Long_Text;

   procedure Long_Text_Route (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Sparrow.Http.Responses.Send (Response, OK, Sparrow.UTF8_String (Long_Text));
   end Long_Text_Route;

   procedure Kept_Text (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Sparrow.Http.Responses.Send (Response, OK, Sparrow.UTF8_String (Long_Text));
      Sparrow.Http.Responses.Set_Header (Response, "Cache-Control", "no-transform");
   end Kept_Text;

   procedure Echo (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Responses.Send_Bytes
        (Response, OK, Sparrow.Http.Requests.Content (Request), "application/octet-stream");
   end Echo;

   --  Says which kind of task ran it, and the :name capture.
   procedure Who (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Responses.Send
        (Response, OK,
         Encoding.To_UTF8 ((if Requests.Worker (Request) = Reactor_Task then "reactor" else "worker") & " "
                       & Sparrow.Http.Requests.Parameter (Request, "name")));
   end Who;

   procedure Slow (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.IO.Process.Sleep (300);
      Who (Request, Response);
   end Slow;

   procedure Traced (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Log.Info (Request, "handled", Sparrow.Http.Log.Field ("n", 7));
      Sparrow.Http.Responses.Send (Response, OK, UTF8_String (Sparrow.Http.Log.Trace_Headers (Request)));
   end Traced;

   procedure Moved (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Sparrow.Http.Responses.Redirect (Response, "/hello");
   end Moved;

   procedure Count_Up (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Responses.Begin_Stream (Response, "text/plain");
      Sparrow.Buffers.Append (Response.Content, "one;");
      Sparrow.Http.Streams.Send (Requests.Connection (Request), "two;");      --  held until the response is out
      Sparrow.Http.Streams.Send (Requests.Connection (Request), "three;");
      Sparrow.Http.Streams.Close (Requests.Connection (Request));
   end Count_Up;

   procedure Watch (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Event_Streams.Begin_Events (Response, Retry => 500);
      Sparrow.Http.Streams.Add (Watchers, Requests.Connection (Request));
   end Watch;

   overriding procedure On_Message
     (This : Echo_Socket; Socket : Connection_Id; Message : String; Binary : Boolean; Context : Handler_Context)
   is
      pragma Unreferenced (This, Context);
   begin
      if Message = "bye" then
         Sparrow.Http.Streams.Close (Socket);
      elsif Message = "boom" then
         raise Constraint_Error with "boom (expected by the test)";
      elsif Binary then
         Sparrow.Http.Streams.Send_Bytes (Socket, Message);
      else
         Sparrow.Http.Streams.Send (Socket, UTF8_String (Ada.Characters.Handling.To_Upper (Message)));
      end if;
   end On_Message;

   overriding procedure On_Close (This : Echo_Socket; Socket : Connection_Id) is
      pragma Unreferenced (This, Socket);
   begin
      Socket_Events.Closed;
   end On_Close;

   protected body Socket_Events is
      procedure Closed is begin
         Close_Total := Close_Total + 1;
      end Closed;
      function Closes return Natural is (Close_Total);
   end Socket_Events;

   procedure Boom (Request : Http_Request; Response : in out Http_Response) is
   begin
      raise Constraint_Error with "boom (expected by the test)";
   end Boom;

   procedure Leave (Request : Http_Request; Response : in out Http_Response) is
      pragma Unreferenced (Request);
   begin
      Sparrow.Http.Responses.Send (Response, OK, "bye");
      Response.Close := True;
   end Leave;

   procedure Count_Start (Worker : Worker_Id) is
      pragma Unreferenced (Worker);
   begin
      Counters.Started;
   end Count_Start;

   procedure Count_Stop (Worker : Worker_Id) is
      pragma Unreferenced (Worker);
   begin
      Counters.Stopped;
   end Count_Stop;

   protected body Counters is
      procedure Started is begin
         Start_Total := Start_Total + 1;
      end Started;
      procedure Stopped is begin
         Stop_Total := Stop_Total + 1;
      end Stopped;
      function Starts return Natural is (Start_Total);
      function Stops return Natural is (Stop_Total);
   end Counters;

   procedure Upload_Sum (Request : Http_Request; Response : in out Http_Response) is
      Part  : String (1 .. 4096);
      Last  : Natural;
      Bytes : Long_Long_Integer := 0;
      Sum   : Long_Long_Integer := 0;
      Reads : Natural := 0;
   begin
      loop
         Sparrow.Http.Bodies.Read (Request, Part, Last);
         exit when Last < Part'First;
         for Byte of Part (1 .. Last) loop
            Sum := Sum + Character'Pos (Byte);
         end loop;
         Bytes := Bytes + Long_Long_Integer (Last);
         Reads := Reads + 1;
         if Reads mod 200 = 0 then
            Sparrow.IO.Process.Sleep (5);   --  slower than the client: the server must hold it back
         end if;
      end loop;
      Sparrow.Http.Responses.Send
        (Response, OK, UTF8_String (Ada.Strings.Fixed.Trim (Bytes'Image, Ada.Strings.Left) & Sum'Image));
   exception
      when Sparrow.Http.Bodies.Body_Error =>
         Body_Errors.Add;
   end Upload_Sum;

   procedure Upload_Part (Request : Http_Request; Response : in out Http_Response) is
      Part : String (1 .. 10);
      Last : Natural;
   begin
      Sparrow.Http.Bodies.Read (Request, Part, Last);
      Sparrow.Http.Responses.Send (Response, OK, "part " & UTF8_String (Part (1 .. Last)));
   end Upload_Part;

   procedure Upload_All (Request : Http_Request; Response : in out Http_Response) is
   begin
      Sparrow.Http.Responses.Send_Bytes
        (Response, OK, Sparrow.Http.Bodies.Read_All (Request, Max_Length => 1000), "application/octet-stream");
   exception
      when Sparrow.Http.Bodies.Body_Error =>
         Body_Errors.Add;
         Sparrow.Http.Responses.Send (Response, Payload_Too_Large, "too long");
   end Upload_All;

   procedure Upload_Form (Request : Http_Request; Response : in out Http_Response) is
      use Sparrow.Http.Multipart;
      Upload : Form;
      Valid  : Boolean;
   begin
      Save_Stream (Request, "obj", Upload, Valid, Max_Field_Length => 100);
      if not Valid then
         Sparrow.Http.Responses.Send (Response, Bad_Request, "invalid");
         return;
      end if;
      declare
         Index : constant Natural := Find (Upload, "file");
         Size  : constant Long_Long_Integer := Saved_Size (Upload, Index);
      begin
         Save (Upload, "file", "obj/upload-moved.bin");
         Discard (Upload);
         Sparrow.Http.Responses.Send
           (Response, OK, Field (Upload, "title") & UTF8_String (Part_Count (Upload)'Image & Size'Image & " "
                                                                 & File_Name (Upload, Index)));
      end;
   end Upload_Form;

   function Any_Key (Request : Http_Request) return String is
      pragma Unreferenced (Request);
   begin
      return "any";
   end Any_Key;

   protected body Body_Errors is
      procedure Add is begin
         Count := Count + 1;
      end Add;
      function Total return Natural is (Count);
   end Body_Errors;

end Http_Test_Handlers;
