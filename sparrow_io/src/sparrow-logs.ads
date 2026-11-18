--  Structured logging: a message, a level and named fields, written one line at a time to standard error (or a
--  sink of your own), as text for people or JSON for log collectors.
--
--     Logs.Info ("cache warmed", Logs.Field ("entries", 1_200), Logs.Field ("source", "disk"));
--
--     2026-11-17T14:21:55.123Z INFO  cache warmed entries=1200 source=disk                      (LOG_FORMAT=text)
--     {"time":"2026-11-17T14:21:55.123Z","level":"info","message":"cache warmed","entries":1200,"source":"disk"}
--
--  LOG_LEVEL (debug, info, warning, error; default info) and LOG_FORMAT (text, json; default text) are read
--  when the program starts; Configure changes them. In a request handler, Sparrow.Http.Log adds the request's
--  id and trace to every line.
--
--  Any task may log. Values are escaped: a client-supplied string cannot forge a line or a field.
--
--  Lines to standard error are batched: each task appends whole lines to a buffer of its own (shared with
--  some other tasks when there are more tasks than processors), and one task writes the buffers out, a batch
--  per system call. So a task's lines stay in order and whole, and logging costs a copy rather than a
--  system call. Batches go out every LOG_FLUSH_MS (default 50), sooner when a buffer is half full, and at
--  once after a warning or an error. When the output cannot keep up, a logging task waits for room
--  (LOG_OVERFLOW=wait, the default) or the line is dropped and counted (LOG_OVERFLOW=drop). LOG_BUFFER=off
--  writes each line at once instead, for chasing crashes: buffered lines are lost when the process is
--  killed. Flush writes what is buffered; Sparrow's server calls it when it stops, and so does the end of
--  the program.
package Sparrow.Logs is

   type Level is (Debug, Info, Warning, Error);
   type Format is (Text, Json);

   --  Named values for a line. The logging procedures take up to six; join more (or build them up) with "&".
   type Fields (<>) is private;
   No_Fields : constant Fields;

   function "&" (Left, Right : Fields) return Fields;

   function Field (Name : String; Value : String) return Fields;
   function Field (Name : String; Value : Long_Long_Integer) return Fields;
   function Field (Name : String; Value : Boolean) return Fields;
   function Field (Name : String; Value : Duration) return Fields;   --  as milliseconds, with microseconds

   procedure Log (At_Level : Level; Message : String; Details : Fields := No_Fields);

   procedure Debug (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Info (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Warning (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);
   procedure Error (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields);

   --  Whether a line at At_Level would be written: skip building costly fields when not.
   function Enabled (At_Level : Level) return Boolean;

   --  A line formatted field by field into a buffer of its own, for code that logs on every request (the
   --  server's access log): it builds no Fields. Declare it where the line is made, so it lives on the stack.
   --
   --     Line : Logs.Line_Builder (Capacity => 2048);
   --     ...
   --     Logs.Start (Line, Logs.Info, "request");
   --     Logs.Add (Line, "status", 200);
   --     Logs.Write (Line);
   --
   --  Nothing is formatted when At_Level is not enabled. A field that might not fit (Capacity is checked
   --  against its worst case, every byte escaped) is left out, and the line ends with truncated=true.
   type Line_Builder (Capacity : Positive) is limited private;

   procedure Start (This : in out Line_Builder; At_Level : Level; Message : String);
   procedure Add (This : in out Line_Builder; Name : String; Value : String);
   procedure Add (This : in out Line_Builder; Name : String; Value : Long_Long_Integer);
   procedure Add (This : in out Line_Builder; Name : String; Value : Duration);   --  milliseconds
   procedure Write (This : in out Line_Builder);

   --  The line Log would write, without its line break (for tests and custom sinks).
   function Format_Line (At_Level : Level; Message : String; Details : Fields := No_Fields) return String;

   procedure Configure (Threshold : Level := Info; Style : Format := Text);

   --  How lines reach standard error (see above): batched or each at once, how often batches go out, and
   --  whether a task waits or drops lines when the output does not keep up.
   type Overflow_Policy is (Wait, Drop);
   procedure Configure_Output
     (Buffered       : Boolean := True;
      Flush_Interval : Duration := 0.05;
      On_Overflow    : Overflow_Policy := Wait)
     with Pre => Flush_Interval in 0.001 .. 60.0;

   --  Write every line buffered so far, and return once they are out.
   procedure Flush;

   --  Where lines go instead of standard error (null: back to it), one call per line, not batched. Called from
   --  any task, possibly at once: a sink must be safe for that.
   type Sink is access procedure (Line : String);
   procedure Set_Sink (To : Sink);

private

   type Line_Builder (Capacity : Positive) is limited record
      Text      : String (1 .. Capacity);
      Last      : Natural := 0;
      At_Level  : Level := Info;
      Active    : Boolean := False;   --  started, at an enabled level
      As_Json   : Boolean := False;
      Truncated : Boolean := False;
   end record;

   --  Each field: Field_Start, the name, Field_Middle, a kind ('s' text, 'n' number, 'b' boolean), the value. Names and
   --  values never contain Field_Start or Field_Middle (they are replaced).
   type Fields is new String;
   No_Fields : constant Fields := "";

   Field_Start  : constant Character := Character'Val (1);
   Field_Middle : constant Character := Character'Val (2);

end Sparrow.Logs;
