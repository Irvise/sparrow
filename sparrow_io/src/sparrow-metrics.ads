--  Metrics: counters, gauges and histograms for a scraper to read, in the Prometheus text format.
--
--     Orders : constant Metrics.Counter := Metrics.New_Counter ("shop_orders_total", "Orders placed.");
--     ...
--     Metrics.Add (Orders);
--
--  Updating a metric is one atomic addition (two for a histogram): safe from any task, never blocking, no
--  allocation. Declaring one takes a lock and allocates its name, and is meant for start-up, as a
--  library-level constant; declaring a name and labels that exist already gives back the same metric. The
--  Sparrow server declares its own (sparrow_http_*), and Sparrow.Http.Health.Metrics serves them all on
--  /metrics.
--
--  Values are whole numbers; a histogram keeps its sum to a millionth (a microsecond, for seconds).
with Sparrow.Buffers;

package Sparrow.Metrics with SPARK_Mode => Off is

   --  name="value" pairs, joined with "&": Label ("route", "/users/:id") & Label ("status", "2xx").
   type Labels is new String;
   No_Labels : constant Labels := "";

   --  Value escaped as the format wants (backslash, quote, line feed).
   function Label (Name : String; Value : String) return Labels;
   function "&" (Left, Right : Labels) return Labels;

   --  Raised by the New_ functions for a malformed name or label name, a name declared before as another
   --  kind of metric, unsorted bounds, or no room left (see Capacity below).
   Invalid_Metric : exception;

   ---------------------------------------------------------------------------------------------------------------
   --  Counters: only go up. Names conventionally end in _total.

   type Counter is private;
   No_Counter : constant Counter;   --  updates to it are ignored

   function New_Counter (Name : String; Help : String; With_Labels : Labels := No_Labels) return Counter;
   procedure Add (This : Counter; Amount : Natural := 1);
   function Value (This : Counter) return Long_Long_Integer;

   ---------------------------------------------------------------------------------------------------------------
   --  Gauges: go up and down (connections open, jobs waiting).

   type Gauge is private;
   No_Gauge : constant Gauge;

   function New_Gauge (Name : String; Help : String; With_Labels : Labels := No_Labels) return Gauge;
   procedure Set (This : Gauge; To : Long_Long_Integer);
   procedure Add (This : Gauge; Amount : Long_Long_Integer);   --  negative to take away
   function Value (This : Gauge) return Long_Long_Integer;

   ---------------------------------------------------------------------------------------------------------------
   --  Histograms: how observations spread over buckets ("le" upper bounds, ascending), with their count and sum.
   --  Times are observed in seconds.

   type Bucket_Bounds is array (Positive range <>) of Long_Float;

   Latency_Bounds : constant Bucket_Bounds := [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0];

   type Histogram is private;
   No_Histogram : constant Histogram;

   --  Every histogram of one name must have the same Bounds.
   function New_Histogram
     (Name        : String;
      Help        : String;
      Bounds      : Bucket_Bounds := Latency_Bounds;
      With_Labels : Labels := No_Labels) return Histogram;
   procedure Observe (This : Histogram; Item : Long_Float);
   procedure Observe (This : Histogram; Elapsed : Duration);
   function Count (This : Histogram) return Long_Long_Integer;

   ---------------------------------------------------------------------------------------------------------------

   --  Every metric declared so far, in the Prometheus text format (version 0.0.4), appended to Into.
   procedure Write_Text (Into : in out Buffers.Buffer);

   Text_Media_Type : constant String := "text/plain; version=0.0.4; charset=utf-8";

   --  Room: 256 names, 4096 series (one per name and label set), 32768 values (a histogram takes one per
   --  bucket, plus two).
   Max_Families : constant := 256;
   Max_Series   : constant := 4096;
   Max_Cells    : constant := 32_768;

private

   subtype Cell_Count is Natural range 0 .. Max_Cells;

   type Counter is record
      First : Cell_Count := 0;   --  0: none
   end record;

   type Gauge is record
      First : Cell_Count := 0;
   end record;

   type Histogram is record
      First  : Cell_Count := 0;
      Family : Natural := 0;
   end record;

   No_Counter   : constant Counter := (First => 0);
   No_Gauge     : constant Gauge := (First => 0);
   No_Histogram : constant Histogram := (First => 0, Family => 0);

end Sparrow.Metrics;
