--  Route patterns ("/articles/:slug", "/static/*file") against request paths: checking a pattern, matching a
--  path, and finding what each capture matched. Sparrow.Http.Routers holds the routes and their handlers.
--
--  SPARK: no run-time errors, and every capture span lies inside the pattern or path it describes.
with Sparrow.Encoding; use Sparrow.Encoding;
with Sparrow.Http.Requests;

package Sparrow.Http.Route_Patterns with SPARK_Mode is

   Max_Captures : constant := Requests.Max_Parameters;

   --  The largest index of a pattern or path, leaving room to step past the end.
   Max_Index : constant := Positive'Last - 2;

   type Problem is
     (None,
      No_Leading_Slash,    --  a pattern starts with '/'
      Bad_Capture_Name,    --  ":name" and "*name" need a name of 1 .. 32 characters
      Star_Not_Last,       --  a '*' capture must be the last segment
      Too_Many_Captures,   --  more than Max_Captures
      Repeated_Name);      --  two captures of one name

   function Check (Pattern : String) return Problem
      with Pre => Pattern'Last <= Max_Index;

   --  Whether Path matches Pattern (a checked one): literal segments match exactly, ":name" any one non-empty
   --  segment, "*name" the rest of the path, even nothing.
   function Matches (Pattern, Path : String) return Boolean
      with Pre => Pattern'First >= 1 and then Pattern'Last <= Max_Index and then Path'First >= 1
                  and then Path'Last <= Max_Index;

   type Capture is record
      Name  : Span := Empty;   --  in the pattern, without its ':' or '*'
      Value : Span := Empty;   --  in the path
   end record;

   type Capture_List is array (1 .. Max_Captures) of Capture;

   --  What each capture of Pattern matched in Path (which matches it), in order.
   procedure Find_Captures (Pattern, Path : String; Captures : out Capture_List; Count : out Natural)
      with Pre  => Pattern'First >= 1 and then Pattern'Last <= Max_Index and then Path'First >= 1
                   and then Path'Last <= Max_Index,
           Post => Count <= Max_Captures
                   and then (for all Index in 1 .. Count =>
                               Within (Captures (Index).Name, Pattern) and then Within (Captures (Index).Value, Path));

end Sparrow.Http.Route_Patterns;
