with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Client;
with Sparrow.Encoding;
with Sparrow.Http.Log;
with Sparrow.Http.Spans; use Sparrow.Http.Spans;
with Sparrow.IO.Process;
with Sparrow.Json.Builders; use Sparrow.Json.Builders;
with Sparrow.Logs;
with Sparrow.Metrics;

package body Sparrow.Open_Telemetry is

   Exported : constant Metrics.Counter :=
     Metrics.New_Counter ("sparrow_open_telemetry_spans_exported_total", "Spans the collector accepted.");
   Dropped_Full : constant Metrics.Counter :=
     Metrics.New_Counter ("sparrow_open_telemetry_spans_dropped_total", "Spans not exported, by reason.",
                          Metrics.Label ("reason", "queue_full"));
   Dropped_Failed : constant Metrics.Counter :=
     Metrics.New_Counter ("sparrow_open_telemetry_spans_dropped_total", "Spans not exported, by reason.",
                          Metrics.Label ("reason", "send_failed"));

   --  What Start was given; read by the sender task, written only while none runs.
   Service_Name : Unbounded_String;
   Url          : Unbounded_String;
   Header_Lines : Unbounded_String;

   type Span_Array is array (Positive range <>) of Finished_Span;
   type Span_Array_Access is access Span_Array;
   procedure Free is new Ada.Unchecked_Deallocation (Span_Array, Span_Array_Access);

   ---------------------------------------------------------------------------------------------------------------
   --  the queue between the tasks that finish spans and the sender

   protected Queue is
      procedure Open (Limit : Positive; Batch : Positive);
      procedure Push (Item : Finished_Span; Accepted : out Boolean);
      procedure Take (Into : out Span_Array; Count : out Natural);   --  the oldest, up to Into'Length
      entry Wait_Work;                                               --  a batch is full, or a flush or close
      procedure Want_Flush;
      procedure Done_Sending;                                        --  ends a flush once nothing is left
      entry Wait_Flushed;
      procedure Close;
      procedure Sender_Ended;
      function Finished return Boolean;                              --  closed and empty
   private
      Ring          : Span_Array_Access;
      Head          : Positive := 1;
      Count         : Natural := 0;
      Batch_Length  : Positive := 1;
      Closing       : Boolean := False;
      Flush_Wanted  : Boolean := False;
      Sender_Gone   : Boolean := True;
   end Queue;

   protected body Queue is

      procedure Open (Limit : Positive; Batch : Positive) is begin
         Free (Ring);
         Ring         := new Span_Array (1 .. Limit);
         Head         := 1;
         Count        := 0;
         Batch_Length := Batch;
         Closing      := False;
         Flush_Wanted := False;
         Sender_Gone  := False;
      end Open;

      procedure Push (Item : Finished_Span; Accepted : out Boolean) is begin
         Accepted := Ring /= null and then not Closing and then Count < Ring'Length;
         if Accepted then
            Ring ((Head - 1 + Count) mod Ring'Length + 1) := Item;
            Count := Count + 1;
         end if;
      end Push;

      procedure Take (Into : out Span_Array; Count : out Natural) is begin
         Count := Natural'Min (Into'Length, Queue.Count);
         for Offset in 0 .. Count - 1 loop
            Into (Into'First + Offset) := Ring (Head);
            Head := Head mod Ring'Length + 1;
         end loop;
         Queue.Count := Queue.Count - Count;
      end Take;

      entry Wait_Work when Count >= Batch_Length or else Closing or else Flush_Wanted is begin
         null;
      end Wait_Work;

      procedure Want_Flush is begin
         Flush_Wanted := not Sender_Gone;
      end Want_Flush;

      procedure Done_Sending is begin
         if Count = 0 then
            Flush_Wanted := False;
         end if;
      end Done_Sending;

      entry Wait_Flushed when not Flush_Wanted is begin
         null;
      end Wait_Flushed;

      procedure Close is begin
         Closing := True;
      end Close;

      procedure Sender_Ended is begin
         Sender_Gone  := True;
         Flush_Wanted := False;
         Count        := 0;
         Free (Ring);
      end Sender_Ended;

      function Finished return Boolean is (Closing and then Count = 0);

   end Queue;

   procedure Enqueue (Item : Finished_Span) is
      Accepted : Boolean;
   begin
      Queue.Push (Item, Accepted);
      if not Accepted then
         Metrics.Add (Dropped_Full);
      end if;
   end Enqueue;

   ---------------------------------------------------------------------------------------------------------------
   --  OTLP/JSON (opentelemetry-proto, trace/v1): ids in hex, times and integers as decimal strings

   function Image (Value : Long_Long_Integer) return String is
      Text : constant String := Value'Image;
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   procedure Attribute (Json : in out Builder; Name : String; Text : String) is begin
      Json.Begin_Object;
      Json.Member ("key", UTF8_String (Name));
      Json.Key ("value");
      Json.Begin_Object;
      Json.Member ("stringValue", UTF8_String (Text));
      Json.End_Object;
      Json.End_Object;
   end Attribute;

   procedure Attribute (Json : in out Builder; Name : String; Number : Long_Long_Integer) is begin
      Json.Begin_Object;
      Json.Member ("key", UTF8_String (Name));
      Json.Key ("value");
      Json.Begin_Object;
      Json.Member ("intValue", UTF8_String (Image (Number)));
      Json.End_Object;
      Json.End_Object;
   end Attribute;

   procedure Write_Span (Json : in out Builder; Item : Finished_Span) is
      Parent : constant String := Http.Log.Parent_Id (Item.Trace);
   begin
      Json.Begin_Object;
      Json.Member ("traceId", UTF8_String (Http.Log.Trace_Id (Item.Trace)));
      Json.Member ("spanId", UTF8_String (Http.Log.Span_Id (Item.Trace)));
      if Parent /= [Parent'Range => '0'] then
         Json.Member ("parentSpanId", UTF8_String (Parent));
      end if;
      Json.Member ("name", UTF8_String (Item.Name (1 .. Item.Name_Length)));
      Json.Member ("kind", Long_Long_Integer (if Item.Kind = Server then 2 else 1));   --  SERVER, INTERNAL
      Json.Member ("startTimeUnixNano", UTF8_String (Image (Long_Long_Integer (Item.Started))));
      Json.Member ("endTimeUnixNano", UTF8_String (Image (Long_Long_Integer (Item.Ended))));
      Json.Key ("attributes");
      Json.Begin_Array;
      if Item.Kind = Server then
         Attribute (Json, "http.request.method", Item.Verb'Image);
         if Item.Route_Length > 0 then
            Attribute (Json, "http.route", Item.Route (1 .. Item.Route_Length));
         end if;
         Attribute (Json, "url.path", Item.Path (1 .. Item.Path_Length));
         Attribute (Json, "http.response.status_code", Long_Long_Integer (Item.Status));
      end if;
      Json.End_Array;
      if Item.Failed then
         Json.Key ("status");
         Json.Begin_Object;
         Json.Member ("code", Long_Long_Integer'(2));   --  STATUS_CODE_ERROR
         Json.End_Object;
      end if;
      Json.End_Object;
   end Write_Span;

   procedure Write_Request (Into : in out Buffer; Items : Span_Array) is
      Json : Builder (Into'Unrestricted_Access);
   begin
      Json.Begin_Object;
      Json.Key ("resourceSpans");
      Json.Begin_Array;
      Json.Begin_Object;
      Json.Key ("resource");
      Json.Begin_Object;
      Json.Key ("attributes");
      Json.Begin_Array;
      Attribute (Json, "service.name", To_String (Service_Name));
      Attribute (Json, "telemetry.sdk.name", "sparrow");
      Attribute (Json, "telemetry.sdk.language", "ada");
      Json.End_Array;
      Json.End_Object;
      Json.Key ("scopeSpans");
      Json.Begin_Array;
      Json.Begin_Object;
      Json.Key ("scope");
      Json.Begin_Object;
      Json.Member ("name", "sparrow");
      Json.End_Object;
      Json.Key ("spans");
      Json.Begin_Array;
      for Item of Items loop
         Write_Span (Json, Item);
      end loop;
      Json.End_Array;
      Json.End_Object;
      Json.End_Array;
      Json.End_Object;
      Json.End_Array;
      Json.End_Object;
   end Write_Request;

   ---------------------------------------------------------------------------------------------------------------
   --  the sender

   Failing : Boolean := False;   --  the last batch failed (one warning per run of failures); the sender's own

   procedure Send (Items : Span_Array) is
      Text    : aliased Buffer;
      Answer  : Client.Response;
      Problem : Unbounded_String;
   begin
      Write_Request (Text, Items);
      begin
         Client.Post (To_String (Url), Content (Text), Answer, Headers => To_String (Header_Lines));
         if Client.Status (Answer) not in 200 .. 299 then
            Problem := To_Unbounded_String ("the collector answered" & Client.Status (Answer)'Image);
         end if;
      exception
         when Occurrence : others =>
            Problem := To_Unbounded_String (Ada.Exceptions.Exception_Message (Occurrence));
      end;
      Free (Text);

      if Length (Problem) = 0 then
         Metrics.Add (Exported, Items'Length);
         if Failing then
            Logs.Info ("trace export works again", Logs.Field ("endpoint", To_String (Url)));
            Failing := False;
         end if;
      else
         Metrics.Add (Dropped_Failed, Items'Length);
         if not Failing then
            Logs.Warning ("trace export failed; spans are dropped until it works",
                          Logs.Field ("endpoint", To_String (Url)), Logs.Field ("error", To_String (Problem)));
            Failing := True;
         end if;
      end if;
   end Send;

   Batch_Length : Positive := 512;

   task type Sender;

   task body Sender is
      Batch : Span_Array_Access := new Span_Array (1 .. Batch_Length);
      Count : Natural;
   begin
      Failing := False;
      loop
         select
            Queue.Wait_Work;
         or
            delay 1.0;
         end select;
         loop
            Queue.Take (Batch.all, Count);
            exit when Count = 0;
            Send (Batch (1 .. Count));
         end loop;
         Queue.Done_Sending;
         exit when Queue.Finished;
      end loop;
      Free (Batch);
      Queue.Sender_Ended;
   exception
      when Occurrence : others =>
         Logs.Error ("trace export stopped", Logs.Field ("error", Ada.Exceptions.Exception_Information (Occurrence)));
         Free (Batch);
         Queue.Sender_Ended;
   end Sender;

   type Sender_Access is access Sender;
   procedure Free is new Ada.Unchecked_Deallocation (Sender, Sender_Access);

   Running : Sender_Access;

   ---------------------------------------------------------------------------------------------------------------

   procedure Start
     (Service      : String;
      Endpoint     : String := Default_Endpoint;
      Sample_Ratio : Long_Float := 1.0;
      Headers      : String := "";
      Queue_Limit  : Positive := 4096;
      Batch_Size   : Positive := 512)
   is begin
      Stop;
      Service_Name := To_Unbounded_String (Service);
      Url          := To_Unbounded_String (Endpoint);
      Header_Lines := To_Unbounded_String (Headers);
      Batch_Length := Batch_Size;
      Queue.Open (Queue_Limit, Batch_Size);
      Running := new Sender;
      Http.Spans.Set_Exporter (Enqueue'Access, Sample_Ratio);
   end Start;

   function Header_Lines_Of (Setting : String) return String is
      Result : Unbounded_String;
      First  : Positive := Setting'First;
   begin
      while First <= Setting'Last loop
         declare
            Comma : constant Natural := Ada.Strings.Fixed.Index (Setting (First .. Setting'Last), ",");
            Last  : constant Natural := (if Comma = 0 then Setting'Last else Comma - 1);
            Pair  : String renames Setting (First .. Last);
            Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
         begin
            if Equal > 0 then
               declare
                  use Ada.Strings;
                  Name    : constant String := Fixed.Trim (Pair (Pair'First .. Equal - 1), Both);
                  Encoded : constant String := Fixed.Trim (Pair (Equal + 1 .. Pair'Last), Both);
                  Value   : String (1 .. Encoded'Length + 1);
                  Final   : Natural;
                  Valid   : Boolean;
               begin
                  Encoding.Percent_Decode (Encoded, Value, Final, Valid);
                  if Valid and then Name'Length > 0 then
                     if Length (Result) > 0 then
                        Append (Result, ASCII.LF);
                     end if;
                     Append (Result, Name & ": " & Value (1 .. Final));
                  end if;
               end;
            end if;
            First := Last + 2;
         end;
      end loop;
      return To_String (Result);
   end Header_Lines_Of;

   procedure Start_From_Environment (Default_Service : String; Started : out Boolean) is
      Traces_Endpoint : constant String := IO.Process.Environment ("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT");
      Base_Endpoint   : constant String := IO.Process.Environment ("OTEL_EXPORTER_OTLP_ENDPOINT");
      Service         : constant String := IO.Process.Environment ("OTEL_SERVICE_NAME");
      Ratio_Text      : constant String := IO.Process.Environment ("OTEL_TRACES_SAMPLER_ARG");
      Ratio           : Long_Float := 1.0;

      function Without_Slash (Text : String) return String is
        (if Text'Length > 0 and then Text (Text'Last) = '/' then Text (Text'First .. Text'Last - 1) else Text);
   begin
      Started := Traces_Endpoint'Length > 0 or else Base_Endpoint'Length > 0;
      if not Started then
         return;
      end if;
      if Ratio_Text'Length > 0 then
         begin
            Ratio := Long_Float'Max (0.0, Long_Float'Min (1.0, Long_Float'Value (Ratio_Text)));
         exception
            when Constraint_Error =>
               Logs.Warning ("OTEL_TRACES_SAMPLER_ARG is not a number; sampling every trace");
         end;
      end if;
      Start (Service      => (if Service'Length > 0 then Service else Default_Service),
             Endpoint     => (if Traces_Endpoint'Length > 0 then Traces_Endpoint
                              else Without_Slash (Base_Endpoint) & "/v1/traces"),
             Sample_Ratio => Ratio,
             Headers      => Header_Lines_Of (IO.Process.Environment ("OTEL_EXPORTER_OTLP_HEADERS")));
   end Start_From_Environment;

   procedure Flush is begin
      if Running /= null then
         Queue.Want_Flush;
         Queue.Wait_Flushed;
      end if;
   end Flush;

   procedure Stop is begin
      if Running = null then
         return;
      end if;
      Http.Spans.Set_Exporter (null, 0.0);
      Queue.Close;
      while not Running'Terminated loop
         delay 0.01;
      end loop;
      Free (Running);
   end Stop;

   function Is_Running return Boolean is (Running /= null);

end Sparrow.Open_Telemetry;
