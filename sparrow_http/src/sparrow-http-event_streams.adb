with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Encoding;

package body Sparrow.Http.Event_Streams is

   procedure Begin_Events (Response : in out Responses.Response; Retry : Natural := 0) is begin
      Responses.Begin_Stream (Response, "text/event-stream; charset=utf-8");
      Responses.Set_Header (Response, "Cache-Control", "no-store");
      Responses.Set_Header (Response, "X-Accel-Buffering", "no");   --  nginx: pass events on as they come
      Response.Heartbeat := True;
      if Retry > 0 then
         Append (Response.Content,
                 "retry: " & Encoding.Decimal_Image (Long_Long_Integer (Retry)) & ASCII.LF & ASCII.LF);
      end if;
   end Begin_Events;

   function Single_Line (Text : String) return String is
      Result : String (1 .. Text'Length);
      Last   : Natural := 0;
   begin
      for Symbol of Text loop
         if Symbol not in ASCII.LF | ASCII.CR then
            Last := Last + 1;
            Result (Last) := Symbol;
         end if;
      end loop;
      return Result (1 .. Last);
   end Single_Line;

   function Event (Data : UTF8_String; Name : String := ""; Id : String := "") return UTF8_String is
      Into  : Buffer;
      Start : Positive := Data'First;
   begin
      if Name'Length > 0 then
         Append (Into, "event: " & Single_Line (Name) & ASCII.LF);
      end if;
      if Id'Length > 0 then
         Append (Into, "id: " & Single_Line (Id) & ASCII.LF);
      end if;
      --  One data line per line of Data (CR LF, CR and LF all end one).
      for Index in Data'Range loop
         if Data (Index) in ASCII.LF | ASCII.CR then
            if not (Data (Index) = ASCII.LF and then Index > Data'First and then Data (Index - 1) = ASCII.CR) then
               Append (Into, "data: " & String (Data (Start .. Index - 1)) & ASCII.LF);
            end if;
            Start := Index + 1;
         end if;
      end loop;
      Append (Into, "data: " & String (Data (Start .. Data'Last)) & ASCII.LF & ASCII.LF);
      return Result : constant UTF8_String := UTF8_String (Content (Into)) do
         Free (Into);
      end return;
   end Event;

   procedure Send (Target : Connection_Id; Data : UTF8_String; Name : String := ""; Id : String := "") is begin
      Streams.Send (Target, Event (Data, Name, Id));
   end Send;

   procedure Send (Audience : in out Streams.Group; Data : UTF8_String; Name : String := ""; Id : String := "") is
   begin
      Streams.Send (Audience, Event (Data, Name, Id));
   end Send;

end Sparrow.Http.Event_Streams;
