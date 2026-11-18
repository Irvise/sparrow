--  Metrics, the health routes, and spans exported to an OpenTelemetry collector (a route of the server under test
--  plays the collector).
with Ada.Strings.Fixed;
with Checks; use Checks;
with Sparrow; use Sparrow;
with Sparrow.Buffers;
with Sparrow.Client;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Health;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;
with Sparrow.Http.Servers;
with Sparrow.Http.Spans;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Iteration;
with Sparrow.Logs;
with Sparrow.Metrics;
with Sparrow.Open_Telemetry;
with Telemetry_Test_Handlers; use Telemetry_Test_Handlers;

procedure Telemetry_Tests is

   function Contains (Text, Part : String) return Boolean is (Ada.Strings.Fixed.Index (Text, Part) > 0);

   ---------------------------------------------------------------------------------------------------------------
   --  Sparrow.Metrics on its own

   procedure Metric_Checks is
      use Sparrow.Metrics;
      Hits   : constant Counter := New_Counter ("test_hits_total", "Hits.", Label ("page", "a""b\c" & ASCII.LF));
      Again  : constant Counter := New_Counter ("test_hits_total", "Hits.", Label ("page", "a""b\c" & ASCII.LF));
      Other  : constant Counter := New_Counter ("test_hits_total", "Hits.", Label ("page", "z"));
      Level  : constant Gauge := New_Gauge ("test_level", "A level." & ASCII.LF & "Two lines.");
      Timing : constant Histogram := New_Histogram ("test_seconds", "Timings.", Bounds => [0.1, 1.0, 2.5]);
      Text   : Sparrow.Buffers.Buffer;
      Raised : Boolean;
   begin
      Add (Hits);
      Add (Again, 2);
      Add (Other);
      Check (Value (Hits) = 3 and then Value (Other) = 1, "a name and labels declared twice are one counter");
      Add (No_Counter);
      Check (Value (No_Counter) = 0, "No_Counter ignores updates");
      Set (Level, 10);
      Add (Level, -3);
      Check (Value (Level) = 7, "a gauge goes up and down");
      Observe (Timing, Long_Float'(0.05));
      Observe (Timing, Long_Float'(0.1));     --  "le" is inclusive
      Observe (Timing, Duration'(2.0));
      Observe (Timing, Long_Float'(30.0));
      Check (Count (Timing) = 4, "a histogram counts");

      Write_Text (Text);
      declare
         Page : constant String := Sparrow.Buffers.Content (Text);
      begin
         Check (Contains (Page, "# HELP test_hits_total Hits." & ASCII.LF & "# TYPE test_hits_total counter" & ASCII.LF
                                & "test_hits_total{page=""a\""b\\c\n""} 3" & ASCII.LF
                                & "test_hits_total{page=""z""} 1" & ASCII.LF),
                "a counter family, labels escaped");
         Check (Contains (Page, "# HELP test_level A level.\nTwo lines." & ASCII.LF & "# TYPE test_level gauge"
                                & ASCII.LF & "test_level 7" & ASCII.LF), "a gauge, help escaped");
         Check (Contains (Page, "test_seconds_bucket{le=""0.1""} 2" & ASCII.LF
                                & "test_seconds_bucket{le=""1""} 2" & ASCII.LF
                                & "test_seconds_bucket{le=""2.5""} 3" & ASCII.LF
                                & "test_seconds_bucket{le=""+Inf""} 4" & ASCII.LF
                                & "test_seconds_sum 32.15" & ASCII.LF
                                & "test_seconds_count 4" & ASCII.LF), "a histogram: cumulative buckets, sum, count");
      end;
      Sparrow.Buffers.Free (Text);

      Check (Label ("a", "1") & No_Labels & Label ("b", "2") = "a=""1"",b=""2""", "labels join with commas");

      declare
         procedure Expect_Invalid (Action : not null access procedure; Name : String) is begin
            Raised := False;
            begin
               Action.all;
            exception
               when Invalid_Metric =>
                  Raised := True;
            end;
            Check (Raised, Name);
         end Expect_Invalid;

         procedure Bad_Name is
            Ignored : constant Counter := New_Counter ("9lives", "x");
         begin
            null;
         end Bad_Name;

         procedure Other_Kind is
            Ignored : constant Gauge := New_Gauge ("test_hits_total", "x");
         begin
            null;
         end Other_Kind;

         procedure Unsorted is
            Ignored : constant Histogram := New_Histogram ("test_unsorted", "x", Bounds => [1.0, 0.5]);
         begin
            null;
         end Unsorted;

         procedure Le_Label is
            Ignored : constant Labels := Label ("le", "1");
         begin
            null;
         end Le_Label;
      begin
         Expect_Invalid (Bad_Name'Access, "a malformed metric name is refused");
         Expect_Invalid (Other_Kind'Access, "a name declared as another kind is refused");
         Expect_Invalid (Unsorted'Access, "unsorted bounds are refused");
         Expect_Invalid (Le_Label'Access, "the label name le is refused");
      end;
   end Metric_Checks;

   ---------------------------------------------------------------------------------------------------------------
   --  sampling

   procedure Sampling_Checks is
      Low  : constant String := [1 .. 18 => 'f'] & "00000000000001";
      High : constant String := [1 .. 18 => '0'] & "ffffffffffffff";
   begin
      Sparrow.Http.Spans.Set_Exporter (null, 0.0);
      Check (not Sparrow.Http.Spans.Sampled_By_Ratio (Low), "ratio 0 samples nothing");
      Sparrow.Http.Spans.Set_Exporter (null, 0.5);
      Check (Sparrow.Http.Spans.Sampled_By_Ratio (Low) and then not Sparrow.Http.Spans.Sampled_By_Ratio (High),
             "a ratio samples by the trace id's last 14 digits");
      Sparrow.Http.Spans.Set_Exporter (null, 1.0);
      Check (Sparrow.Http.Spans.Sampled_By_Ratio (High), "ratio 1 samples every trace");
      Sparrow.Http.Spans.Set_Exporter (null, 0.0);
   end Sampling_Checks;

   ---------------------------------------------------------------------------------------------------------------
   --  the server

   Port      : constant := 18_479;
   Base      : constant String := "http://127.0.0.1:18479";
   Caller    : constant String := "4bf92f3577b34da6a3ce929d0e0e4736";
   Caller_Of : constant String := "00f067aa0ba902b7";

   Routes : Router (8);

   task Server is
      entry Start;
      entry Finished (Problem : out Boolean);
   end Server;

   task body Server is
      Failed : Boolean := False;
   begin
      accept Start;
      begin
         Servers.Run (Settings => (Port => Port, Reactors => 1, Workers => 2, Catch_Signals => False,
                                   Access_Log => False, others => <>),
                      Routes   => Routes);
      exception
         when others =>
            Failed := True;
      end;
      accept Finished (Problem : out Boolean) do
         Problem := Failed;
      end Finished;
   end Server;

   function Fetch (Path : String; Headers : String := "") return String is
      Answer : Sparrow.Client.Response;
   begin
      Sparrow.Client.Get (Base & Path, Answer, Headers => Headers);
      return Sparrow.Client.Status (Answer)'Image & " " & Sparrow.Client.Content (Answer);
   end Fetch;

   --  One exported span, read back from the collector's bodies.
   type Exported_Span is record
      Trace_Id, Span_Id, Parent_Id : String (1 .. 32) := [others => ' '];
      Name                         : String (1 .. 40) := [others => ' '];
      Kind                         : Long_Long_Integer := 0;
      Failed                       : Boolean := False;
      Status                       : Long_Long_Integer := 0;
      Route                        : String (1 .. 40) := [others => ' '];
   end record;

   type Span_List is array (Positive range <>) of Exported_Span;

   function Padded (Text : String; Size : Positive) return String is
     (Text & [1 .. Size - Text'Length => ' ']);

   procedure Read_Spans (Found : out Span_List; Count : out Natural; Service_Named : out Boolean) is
      Doc   : Document (Node_Capacity => 2048, Text_Capacity => 65_536);
      Valid : Boolean;
   begin
      Count := 0;
      Service_Named := True;
      for Text of Collector.Bodies loop
         Parse (Doc, Text, Valid);
         Check (Valid, "the export is JSON");
         Service_Named := Service_Named
           and then Sparrow.Json.Text (Doc, "resourceSpans.0.resource.attributes.0.value.stringValue")
                    = "telemetry-tests";
         for Item in Sparrow.Json.Iteration.Elements (Doc, "resourceSpans.0.scopeSpans.0.spans") loop
            exit when Count = Found'Length;
            Count := Count + 1;
            declare
               Result : Exported_Span renames Found (Count);
            begin
               Result.Trace_Id  := Padded (String (Sparrow.Json.Text (Doc, "traceId", From => Item)), 32);
               Result.Span_Id   := Padded (String (Sparrow.Json.Text (Doc, "spanId", From => Item)), 32);
               Result.Parent_Id := Padded (String (Sparrow.Json.Text (Doc, "parentSpanId", From => Item)), 32);
               Result.Name      := Padded (String (Sparrow.Json.Text (Doc, "name", From => Item)), 40);
               Result.Kind      := Integer_Value (Doc, "kind", From => Item);
               Result.Failed    := Integer_Value (Doc, "status.code", From => Item) = 2;
               for Attribute in Sparrow.Json.Iteration.Elements (Doc, "attributes", From => Item) loop
                  if Sparrow.Json.Text (Doc, "key", From => Attribute) = "http.response.status_code" then
                     Result.Status := Long_Long_Integer'Value
                       (String (Sparrow.Json.Text (Doc, "value.intValue", From => Attribute)));
                  elsif Sparrow.Json.Text (Doc, "key", From => Attribute) = "http.route" then
                     Result.Route := Padded (String (Sparrow.Json.Text (Doc, "value.stringValue",
                                                                         From => Attribute)), 40);
                  end if;
               end loop;
            end;
         end loop;
      end loop;
   end Read_Spans;

   function Find (Spans : Span_List; Name : String) return Natural is
   begin
      for Index in Spans'Range loop
         if Spans (Index).Name = Padded (Name, 40) then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   Problem : Boolean;

begin
   Metric_Checks;
   Sampling_Checks;

   Health.Add (Routes, Check => Database_Ready'Access);
   Add (Routes, Post, "/v1/traces", Collect'Access);
   Add (Routes, Get, "/work", Work'Access);
   Server.Start;

   --  Sample only what callers ask for, so that the export's own requests are not traced.
   Open_Telemetry.Start (Service => "telemetry-tests", Endpoint => Base & "/v1/traces", Sample_Ratio => 0.0);
   for Attempt in 1 .. 200 loop
      exit when Contains (Fetch ("/healthz"), "200");
      delay 0.01;
   end loop;

   Equal (Fetch ("/healthz"), " 200 ok", "/healthz");
   Equal (Fetch ("/readyz"), " 200 ready", "/readyz when the check passes");
   Database_Up := False;
   Equal (Fetch ("/readyz"), " 503 not ready", "/readyz when the check fails");
   Database_Up := True;

   declare
      Traced   : constant String := Fetch ("/work", "traceparent: 00-" & Caller & "-" & Caller_Of & "-01");
      Untraced : constant String := Fetch ("/work");
      Found    : Span_List (1 .. 10);
      Count    : Natural;
      Named    : Boolean;
   begin
      Check (Contains (Traced, "traceparent: 00-" & Caller & "-"), "a span passes its trace on");
      Check (Contains (Untraced, "-00" & ASCII.LF), "an unsampled trace is passed on as unsampled");
      Open_Telemetry.Flush;
      Read_Spans (Found, Count, Named);
      Check (Count = 3, "a sampled request exports three spans; an unsampled one none:" & Count'Image);
      Check (Named, "spans carry service.name");
      declare
         Server_Span : constant Natural := Find (Found (1 .. Count), "GET /work");
         Outer       : constant Natural := Find (Found (1 .. Count), "inner work");
         Inner       : constant Natural := Find (Found (1 .. Count), "nested step");
      begin
         Check (Server_Span > 0 and then Outer > 0 and then Inner > 0, "the server's span and both handler spans");
         if Server_Span > 0 and then Outer > 0 and then Inner > 0 then
            Check ((for all Item of Found (1 .. Count) => Item.Trace_Id = Padded (Caller, 32)),
                   "every span is in the caller's trace");
            Check (Found (Server_Span).Parent_Id = Padded (Caller_Of, 32), "the request's span hangs under the caller");
            Check (Found (Outer).Parent_Id = Found (Server_Span).Span_Id, "a handler span hangs under the request's");
            Check (Found (Inner).Parent_Id = Found (Outer).Span_Id, "a nested span hangs under its parent");
            Check (Found (Server_Span).Kind = 2 and then Found (Outer).Kind = 1, "kinds: server, internal");
            Check (Found (Server_Span).Status = 200 and then Found (Server_Span).Route = Padded ("/work", 40),
                   "the request's status and route");
            Check (Found (Inner).Failed and then not Found (Outer).Failed, "Fail marks a span as an error");
            Check (Contains (Traced, String (Found (Outer).Span_Id (1 .. 16))),
                   "Trace_Headers of a span's context names that span");
         end if;
      end;
   end;

   declare
      Page : constant String := Fetch ("/metrics");
   begin
      Check (Contains (Page, "sparrow_http_requests_total{method=""GET"",route=""/work"",status=""2xx""} 2"),
             "requests are counted by route and status class");
      Check (Contains (Page, "sparrow_http_requests_total{method=""GET"",route=""/readyz"",status=""5xx""} 1"),
             "a 503 counts as 5xx");
      Check (Contains (Page, "sparrow_http_request_duration_seconds_count{method=""GET"",route=""/work""} 2"),
             "latency is observed by route");
      Check (Contains (Page, "sparrow_http_connections{mode=""http""}"), "connections by mode");
      Check (Contains (Page, "sparrow_open_telemetry_spans_exported_total 3"), "exported spans are counted");
      Check (Contains (Page, "test_hits_total"), "the application's metrics are served too");
   end;

   --  A collector that cannot be reached: spans are dropped and counted, requests do not wait. (The warning it
   --  logs is expected; it is kept out of the output.)
   Sparrow.Logs.Configure (Threshold => Sparrow.Logs.Error);
   Open_Telemetry.Start (Service => "telemetry-tests", Endpoint => "http://127.0.0.1:1/v1/traces");
   Equal (Fetch ("/healthz"), " 200 ok", "requests go on while the collector is down");
   Open_Telemetry.Flush;
   Check (Contains (Fetch ("/metrics"), "sparrow_open_telemetry_spans_dropped_total{reason=""send_failed""} 1"),
          "spans that could not be sent are counted");
   Open_Telemetry.Stop;
   Check (not Open_Telemetry.Is_Running, "Stop ends the exporter");

   Servers.Stop;
   Check (Servers.Is_Stopping, "Is_Stopping once Stop is called");
   Server.Finished (Problem);
   Check (not Problem, "the server ran and stopped");
   Finish ("telemetry");
end Telemetry_Tests;
