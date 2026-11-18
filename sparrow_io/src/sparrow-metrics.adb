with System.Atomic_Operations.Integer_Arithmetic;

package body Sparrow.Metrics with SPARK_Mode => Off is

   use Sparrow.Buffers;

   type Cell is new Long_Long_Integer with Atomic;
   package Atomics is new System.Atomic_Operations.Integer_Arithmetic (Cell);

   type Metric_Kind is (Counter_Kind, Gauge_Kind, Histogram_Kind);

   type Bounds_Access is access constant Bucket_Bounds;

   type Family is record
      Name   : String_Access;
      Help   : String_Access;
      Kind   : Metric_Kind := Counter_Kind;
      Bounds : Bounds_Access;   --  histograms
   end record;

   type Series is record
      Family : Positive := 1;
      Set    : String_Access;   --  the labels, without braces
      First  : Positive := 1;
   end record;

   --  Written under Registry's lock and only appended to; a total is raised after its entry is complete, so a
   --  reader that takes the total first sees whole entries.
   Families     : array (1 .. Max_Families) of Family;
   Series_Table : array (1 .. Max_Series) of Series;
   Cells        : array (1 .. Max_Cells) of aliased Cell := [others => 0];

   Family_Total : Natural := 0 with Atomic;
   Series_Total : Natural := 0 with Atomic;
   Cell_Total   : Natural := 0;

   ---------------------------------------------------------------------------------------------------------------
   --  names and labels

   function Valid_Name (Name : String; Colons : Boolean) return Boolean is
      function Allowed (Item : Character; First : Boolean) return Boolean is
        (Item in 'a' .. 'z' | 'A' .. 'Z' | '_' or else (Colons and then Item = ':')
         or else (not First and then Item in '0' .. '9'));
   begin
      if Name'Length = 0 then
         return False;
      end if;
      for Index in Name'Range loop
         if not Allowed (Name (Index), Index = Name'First) then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Name;

   --  Text with backslash and line feed escaped, and the quote too when Quote.
   function Escaped (Text : String; Quote : Boolean) return String is
      Result : String (1 .. 2 * Text'Length);
      Last   : Natural := 0;
   begin
      for Item of Text loop
         if Item = '\' or else (Quote and then Item = '"') then
            Result (Last + 1 .. Last + 2) := '\' & Item;
            Last := Last + 2;
         elsif Item = ASCII.LF then
            Result (Last + 1 .. Last + 2) := "\n";
            Last := Last + 2;
         else
            Last := Last + 1;
            Result (Last) := Item;
         end if;
      end loop;
      return Result (1 .. Last);
   end Escaped;

   function Label (Name : String; Value : String) return Labels is begin
      if not Valid_Name (Name, Colons => False) or else Name = "le" then
         raise Invalid_Metric with "label name """ & Name & """";
      end if;
      return Labels (Name & "=""" & Escaped (Value, Quote => True) & """");
   end Label;

   function "&" (Left, Right : Labels) return Labels is
     (if Left'Length = 0 then Right
      elsif Right'Length = 0 then Left
      else Labels (String (Left) & "," & String (Right)));

   ---------------------------------------------------------------------------------------------------------------
   --  declaring

   function Same (Left, Right : Bucket_Bounds) return Boolean is
     (Left'Length = Right'Length
      and then (for all Offset in 0 .. Left'Length - 1 => Left (Left'First + Offset) = Right (Right'First + Offset)));

   protected Registry is
      --  The first cell of the series Name{Set}, declared now if it is new; and its family.
      procedure Find_Or_Add
        (Name    : String;
         Help    : String;
         Kind    : Metric_Kind;
         Bounds  : Bucket_Bounds;
         Set     : String;
         First   : out Positive;
         Of_Name : out Positive);
   end Registry;

   protected body Registry is

      procedure Find_Or_Add
        (Name    : String;
         Help    : String;
         Kind    : Metric_Kind;
         Bounds  : Bucket_Bounds;
         Set     : String;
         First   : out Positive;
         Of_Name : out Positive)
      is
         Found : Natural := 0;
         Width : constant Positive := (if Kind = Histogram_Kind then Bounds'Length + 2 else 1);
      begin
         for Index in 1 .. Family_Total loop
            if Families (Index).Name.all = Name then
               Found := Index;
               exit;
            end if;
         end loop;

         if Found = 0 then
            if Family_Total = Max_Families then
               raise Invalid_Metric with "more than" & Max_Families'Image & " metric names";
            end if;
            Families (Family_Total + 1) :=
              (Name   => new String'(Name),
               Help   => new String'(Help),
               Kind   => Kind,
               Bounds => (if Kind = Histogram_Kind then new Bucket_Bounds'(Bounds) else null));
            Family_Total := Family_Total + 1;
            Found := Family_Total;
         elsif Families (Found).Kind /= Kind then
            raise Invalid_Metric with Name & " is declared already as another kind of metric";
         elsif Kind = Histogram_Kind and then not Same (Families (Found).Bounds.all, Bounds) then
            raise Invalid_Metric with Name & " is declared already with other bounds";
         end if;
         Of_Name := Found;

         for Index in 1 .. Series_Total loop
            if Series_Table (Index).Family = Found and then Series_Table (Index).Set.all = Set then
               First := Series_Table (Index).First;
               return;
            end if;
         end loop;

         if Series_Total = Max_Series or else Cell_Total + Width > Max_Cells then
            raise Invalid_Metric with "no room for " & Name & " (see Sparrow.Metrics.Max_Series)";
         end if;
         First := Cell_Total + 1;
         Cell_Total := Cell_Total + Width;
         Series_Table (Series_Total + 1) := (Family => Found, Set => new String'(Set), First => First);
         Series_Total := Series_Total + 1;
      end Find_Or_Add;

   end Registry;

   function Declare_Series
     (Name   : String;
      Help   : String;
      Kind   : Metric_Kind;
      Set    : Labels;
      Bounds : Bucket_Bounds := [1 .. 0 => 0.0]) return Positive
   is
      First   : Positive;
      Of_Name : Positive;
   begin
      if not Valid_Name (Name, Colons => True) then
         raise Invalid_Metric with "metric name """ & Name & """";
      end if;
      Registry.Find_Or_Add (Name, Help, Kind, Bounds, String (Set), First, Of_Name);
      return First;
   end Declare_Series;

   ---------------------------------------------------------------------------------------------------------------
   --  counters and gauges

   function New_Counter (Name : String; Help : String; With_Labels : Labels := No_Labels) return Counter is
     (First => Declare_Series (Name, Help, Counter_Kind, With_Labels));

   procedure Add (This : Counter; Amount : Natural := 1) is begin
      if This.First /= 0 then
         Atomics.Atomic_Add (Cells (This.First), Cell (Amount));
      end if;
   end Add;

   function Value (This : Counter) return Long_Long_Integer is
     (if This.First = 0 then 0 else Long_Long_Integer (Cells (This.First)));

   function New_Gauge (Name : String; Help : String; With_Labels : Labels := No_Labels) return Gauge is
     (First => Declare_Series (Name, Help, Gauge_Kind, With_Labels));

   procedure Set (This : Gauge; To : Long_Long_Integer) is begin
      if This.First /= 0 then
         Cells (This.First) := Cell (To);
      end if;
   end Set;

   procedure Add (This : Gauge; Amount : Long_Long_Integer) is begin
      if This.First /= 0 then
         Atomics.Atomic_Add (Cells (This.First), Cell (Amount));
      end if;
   end Add;

   function Value (This : Gauge) return Long_Long_Integer is
     (if This.First = 0 then 0 else Long_Long_Integer (Cells (This.First)));

   ---------------------------------------------------------------------------------------------------------------
   --  histograms: one cell per bound, one for +Inf (each counts its own bucket only), then the sum in millionths

   function New_Histogram
     (Name        : String;
      Help        : String;
      Bounds      : Bucket_Bounds := Latency_Bounds;
      With_Labels : Labels := No_Labels) return Histogram
   is
      First : Positive;
   begin
      if Bounds'Length = 0
        or else (for some Index in Bounds'First .. Bounds'Last - 1 => Bounds (Index) >= Bounds (Index + 1))
      then
         raise Invalid_Metric with Name & ": bounds must be ascending";
      end if;
      First := Declare_Series (Name, Help, Histogram_Kind, With_Labels, Bounds);
      for Index in 1 .. Family_Total loop
         if Families (Index).Name.all = Name then
            return (First => First, Family => Index);
         end if;
      end loop;
      raise Program_Error;   --  Declare_Series has just added it
   end New_Histogram;

   Largest_Sum : constant Long_Float := 9.0E12;   --  in units: a millionth of it still fits a cell many times

   procedure Observe (This : Histogram; Item : Long_Float) is begin
      if This.First = 0 or else Item /= Item then   --  NaN: not recorded
         return;
      end if;
      declare
         Bounds : Bucket_Bounds renames Families (This.Family).Bounds.all;
         Bucket : Natural := Bounds'Length;   --  +Inf
         Clamped : constant Long_Float := Long_Float'Max (-Largest_Sum, Long_Float'Min (Largest_Sum, Item));
      begin
         for Index in Bounds'Range loop
            if Item <= Bounds (Index) then
               Bucket := Index - Bounds'First;
               exit;
            end if;
         end loop;
         Atomics.Atomic_Add (Cells (This.First + Bucket), 1);
         Atomics.Atomic_Add (Cells (This.First + Bounds'Length + 1), Cell (Clamped * 1.0E6));
      end;
   end Observe;

   procedure Observe (This : Histogram; Elapsed : Duration) is begin
      Observe (This, Long_Float (Elapsed));
   end Observe;

   function Count (This : Histogram) return Long_Long_Integer is
      Total : Long_Long_Integer := 0;
   begin
      if This.First /= 0 then
         for Offset in 0 .. Families (This.Family).Bounds'Length loop
            Total := Total + Long_Long_Integer (Cells (This.First + Offset));
         end loop;
      end if;
      return Total;
   end Count;

   ---------------------------------------------------------------------------------------------------------------
   --  the text format

   function Whole_Image (Value : Long_Long_Integer) return String is
      Text : constant String := Value'Image;
   begin
      return (if Text (Text'First) = ' ' then Text (Text'First + 1 .. Text'Last) else Text);
   end Whole_Image;

   --  Millionths as a decimal: 2500000 is "2.5", 5000 is "0.005".
   function Decimal_Image (Millionths : Long_Long_Integer) return String is
      Size     : constant Long_Long_Integer := abs Millionths;
      Fraction : constant String := Whole_Image (1_000_000 + Size mod 1_000_000);   --  "1" & six digits
      Last     : Natural := Fraction'Last;
   begin
      while Last > Fraction'First and then Fraction (Last) = '0' loop
         Last := Last - 1;
      end loop;
      return (if Millionths < 0 then "-" else "") & Whole_Image (Size / 1_000_000)
             & (if Last = Fraction'First then "" else "." & Fraction (Fraction'First + 1 .. Last));
   end Decimal_Image;

   function Bound_Image (Bound : Long_Float) return String is
     (Decimal_Image (Long_Long_Integer (Long_Float'Max (-Largest_Sum, Long_Float'Min (Largest_Sum, Bound)) * 1.0E6)));

   procedure Write_Text (Into : in out Buffer) is
      Names : constant Natural := Family_Total;
      Total : constant Natural := Series_Total;

      function Braced (Set : String; Extra : String := "") return String is
        (if Set'Length = 0 and then Extra'Length = 0 then ""
         elsif Set'Length = 0 then "{" & Extra & "}"
         elsif Extra'Length = 0 then "{" & Set & "}"
         else "{" & Set & "," & Extra & "}");
   begin
      for Index in 1 .. Names loop
         declare
            Item : Family renames Families (Index);
            Name : String renames Item.Name.all;
         begin
            Append (Into, "# HELP " & Name & " " & Escaped (Item.Help.all, Quote => False) & ASCII.LF);
            Append (Into, "# TYPE " & Name & " "
                          & (case Item.Kind is
                               when Counter_Kind   => "counter",
                               when Gauge_Kind     => "gauge",
                               when Histogram_Kind => "histogram") & ASCII.LF);
            for Entry_Index in 1 .. Total loop
               declare
                  Entry_Item : Series renames Series_Table (Entry_Index);
                  Set        : String renames Entry_Item.Set.all;
               begin
                  if Entry_Item.Family = Index then
                     if Item.Kind /= Histogram_Kind then
                        Append (Into, Name & Braced (Set) & " "
                                      & Whole_Image (Long_Long_Integer (Cells (Entry_Item.First))) & ASCII.LF);
                     else
                        declare
                           Bounds     : Bucket_Bounds renames Item.Bounds.all;
                           Cumulative : Long_Long_Integer := 0;
                        begin
                           for Offset in 0 .. Bounds'Length loop
                              Cumulative := Cumulative + Long_Long_Integer (Cells (Entry_Item.First + Offset));
                              Append (Into, Name & "_bucket"
                                            & Braced (Set, "le="""
                                                           & (if Offset = Bounds'Length then "+Inf"
                                                              else Bound_Image (Bounds (Bounds'First + Offset)))
                                                           & """")
                                            & " " & Whole_Image (Cumulative) & ASCII.LF);
                           end loop;
                           Append (Into, Name & "_sum" & Braced (Set) & " "
                                         & Decimal_Image (Long_Long_Integer
                                                            (Cells (Entry_Item.First + Bounds'Length + 1)))
                                         & ASCII.LF);
                           Append (Into, Name & "_count" & Braced (Set) & " " & Whole_Image (Cumulative) & ASCII.LF);
                        end;
                     end if;
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Write_Text;

end Sparrow.Metrics;
