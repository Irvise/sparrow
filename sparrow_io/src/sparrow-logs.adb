with Ada.Characters.Handling;
with Ada.Finalization;
with Ada.Task_Identification;
with Ada.Unchecked_Deallocation;
with Sparrow.Encoding;
with Sparrow.IO.Process;
with Sparrow.Metrics;
with Sparrow.Times;

package body Sparrow.Logs is

   Threshold_Now : Level := Info with Atomic;
   Style_Now     : Format := Text with Atomic;
   Sink_Now      : Sink := null with Atomic;

   function "&" (Left, Right : Fields) return Fields is (Fields (String (Left) & String (Right)));

   function Clean (Text : String) return String is
      Result : String := Text;
   begin
      for Symbol of Result loop
         if Symbol in Field_Start | Field_Middle then
            Symbol := '?';
         end if;
      end loop;
      return Result;
   end Clean;

   function Is_Clean (Text : String) return Boolean is
     (for all Symbol of Text => Symbol not in Field_Start | Field_Middle);

   --  Copied once when nothing needs replacing, the usual case.
   function Make (Name : String; Kind : Character; Value : String) return Fields is
     (if Is_Clean (Name) and then Is_Clean (Value) then Fields (Field_Start & Name & Field_Middle & Kind & Value)
      else Fields (Field_Start & Clean (Name) & Field_Middle & Kind & Clean (Value)));

   function Field (Name : String; Value : String) return Fields is (Make (Name, 's', Value));

   function Field (Name : String; Value : Long_Long_Integer) return Fields is
     (Make (Name, 'n', Encoding.Decimal_Image (Value)));

   function Field (Name : String; Value : Boolean) return Fields is
     (Make (Name, 'b', (if Value then "true" else "false")));

   function Milliseconds_Image (Value : Duration) return String;

   function Field (Name : String; Value : Duration) return Fields is (Make (Name, 'n', Milliseconds_Image (Value)));

   function Enabled (At_Level : Level) return Boolean is (At_Level >= Threshold_Now);

   procedure Configure (Threshold : Level := Info; Style : Format := Text) is begin
      Threshold_Now := Threshold;
      Style_Now     := Style;
   end Configure;

   procedure Set_Sink (To : Sink) is begin
      Sink_Now := To;
   end Set_Sink;

   ---------------------------------------------------------------------------------------------------------------
   --  formatting, in one pass into a buffer sized for the worst case (every byte escaped as \u00XX)

   Hex : constant String := "0123456789abcdef";

   procedure Put (Into : in out String; Last : in out Natural; Part : String) with Inline is begin
      Into (Last + 1 .. Last + Part'Length) := Part;
      Last := Last + Part'Length;
   end Put;

   procedure Put (Into : in out String; Last : in out Natural; Symbol : Character) with Inline is begin
      Last := Last + 1;
      Into (Last) := Symbol;
   end Put;

   --  Text inside a JSON string. Text that is not UTF-8 has its bytes above 127 escaped as code points, so the
   --  line stays valid JSON.
   procedure Put_Json (Into : in out String; Last : in out Natural; Text : String) is
      Valid : constant Boolean := (for all Symbol of Text => Symbol < Character'Val (128))
                                  or else Encoding.Valid_Utf8 (Text);

      procedure Put_Code (Symbol : Character) is begin
         Put (Into, Last, "\u00");
         Put (Into, Last, Hex (Character'Pos (Symbol) / 16 + 1));
         Put (Into, Last, Hex (Character'Pos (Symbol) mod 16 + 1));
      end Put_Code;
   begin
      for Symbol of Text loop
         case Symbol is
            when '"'      => Put (Into, Last, "\""");
            when '\'      => Put (Into, Last, "\\");
            when ASCII.LF => Put (Into, Last, "\n");
            when ASCII.CR => Put (Into, Last, "\r");
            when ASCII.HT => Put (Into, Last, "\t");
            when Character'Val (0) .. Character'Val (8) | Character'Val (11) .. Character'Val (12)
               | Character'Val (14) .. Character'Val (31) | Character'Val (127) =>
               Put_Code (Symbol);
            when Character'Val (128) .. Character'Val (255) =>
               if Valid then
                  Put (Into, Last, Symbol);
               else
                  Put_Code (Symbol);
               end if;
            when others => Put (Into, Last, Symbol);
         end case;
      end loop;
   end Put_Json;

   --  A value in a text line: bare when it is plain, quoted and escaped otherwise.
   procedure Put_Text_Value (Into : in out String; Last : in out Natural; Text : String) is begin
      if Text'Length > 0
        and then (for all Symbol of Text => Symbol in '!' .. '~' and then Symbol not in '"' | '=' | '\')
      then
         Put (Into, Last, Text);
      else
         Put (Into, Last, '"');
         Put_Json (Into, Last, Text);
         Put (Into, Last, '"');
      end if;
   end Put_Text_Value;

   --  A message in a text line: as it is, but with control characters escaped, so it stays one line.
   procedure Put_Message (Into : in out String; Last : in out Natural; Text : String) is begin
      if (for all Symbol of Text => Symbol >= ' ' and then Symbol /= Character'Val (127)) then
         Put (Into, Last, Text);
      else
         Put_Json (Into, Last, Text);
      end if;
   end Put_Message;

   function Level_Name (At_Level : Level) return String is
     (case At_Level is when Debug => "debug", when Info => "info", when Warning => "warning", when Error => "error");

   Level_Columns : constant array (Level) of String (1 .. 8) :=
     [Debug => "DEBUG   ", Info => "INFO    ", Warning => "WARNING ", Error => "ERROR   "];

   --  The timestamp, from a per-task copy of all but its milliseconds, remade once a second.
   Cached_Second : Long_Long_Integer := Long_Long_Integer'First with Thread_Local_Storage;
   Cached_Head   : String (1 .. 20) := "0000-00-00T00:00:00." with Thread_Local_Storage;

   function Timestamp return Times.Rfc3339_Text is
      use type Times.Unix_Microseconds;
      Now    : Times.Unix_Microseconds;
      Second : Long_Long_Integer;
      Millis : Natural;
   begin
      IO.Process.Read_Clock (Now);
      if Now < 0 then
         return Times.Rfc3339 (Now);
      end if;
      Second := Long_Long_Integer (Now / 1_000_000);
      Millis := Natural (Now mod 1_000_000 / 1000);
      if Second /= Cached_Second then
         Cached_Head   := Times.Rfc3339 (Times.Unix_Microseconds (Second) * 1_000_000) (1 .. 20);
         Cached_Second := Second;
      end if;
      return Cached_Head & [Character'Val (48 + Millis / 100), Character'Val (48 + Millis / 10 mod 10),
                            Character'Val (48 + Millis mod 10), 'Z'];
   end Timestamp;

   procedure Format_Into
     (Into     : in out String;
      Last     : out Natural;
      At_Level : Level;
      Message  : String;
      Details  : Fields)
   is
      Items    : String renames String (Details);
      As_Json  : constant Boolean := Style_Now = Json;
      Position : Natural := Items'First;
   begin
      Last := Into'First - 1;
      if As_Json then
         Put (Into, Last, "{""time"":""");
         Put (Into, Last, Timestamp);
         Put (Into, Last, """,""level"":""");
         Put (Into, Last, Level_Name (At_Level));
         Put (Into, Last, """,""message"":""");
         Put_Json (Into, Last, Message);
         Put (Into, Last, '"');
      else
         Put (Into, Last, Timestamp);
         Put (Into, Last, ' ');
         Put (Into, Last, Level_Columns (At_Level));
         Put_Message (Into, Last, Message);
      end if;

      --  Each field: Field_Start, the name, Field_Middle, the kind, the value.
      while Position <= Items'Last and then Items (Position) = Field_Start loop
         declare
            Name_Last  : Natural := Position;
            Value_Last : Natural;
         begin
            while Name_Last < Items'Last and then Items (Name_Last + 1) /= Field_Middle loop
               Name_Last := Name_Last + 1;
            end loop;
            exit when Name_Last + 2 > Items'Last;
            Value_Last := Name_Last + 2;
            while Value_Last < Items'Last and then Items (Value_Last + 1) /= Field_Start loop
               Value_Last := Value_Last + 1;
            end loop;
            declare
               Name  : String renames Items (Position + 1 .. Name_Last);
               Kind  : constant Character := Items (Name_Last + 2);
               Value : String renames Items (Name_Last + 3 .. Value_Last);
            begin
               if As_Json then
                  Put (Into, Last, ",""");
                  Put_Json (Into, Last, Name);
                  Put (Into, Last, """:");
                  if Kind = 's' then
                     Put (Into, Last, '"');
                     Put_Json (Into, Last, Value);
                     Put (Into, Last, '"');
                  else
                     Put (Into, Last, Value);
                  end if;
               else
                  Put (Into, Last, ' ');
                  Put_Text_Value (Into, Last, Name);
                  Put (Into, Last, '=');
                  if Kind = 's' then
                     Put_Text_Value (Into, Last, Value);
                  else
                     Put (Into, Last, Value);
                  end if;
               end if;
            end;
            Position := Value_Last + 1;
         end;
      end loop;
      if As_Json then
         Put (Into, Last, '}');
      end if;
   end Format_Into;

   --  Room for any line of this message and these fields: six bytes for each escaped byte, plus the fixed parts.
   function Worst_Length (Message : String; Details : Fields) return Positive is
     (96 + 6 * Message'Length + 8 * Details'Length);

   function Format_Line (At_Level : Level; Message : String; Details : Fields := No_Fields) return String is
      type Text_Access is access String;
      procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);
      Room : constant Positive := Worst_Length (Message, Details);
   begin
      if Room <= 16_384 then
         declare
            Line : String (1 .. Room);
            Last : Natural;
         begin
            Format_Into (Line, Last, At_Level, Message, Details);
            return Line (1 .. Last);
         end;
      else
         declare
            Line : Text_Access := new String (1 .. Room);
            Last : Natural;
         begin
            Format_Into (Line.all, Last, At_Level, Message, Details);
            return Result : constant String := Line (1 .. Last) do
               Free (Line);
            end return;
         end;
      end if;
   end Format_Line;

   ---------------------------------------------------------------------------------------------------------------
   --  lines built field by field

   Line_Close : constant := 32;   --  kept free for the end of a line: ' truncated=true' or ',"truncated":true}'

   procedure Start (This : in out Line_Builder; At_Level : Level; Message : String) is begin
      This.Last      := 0;
      This.At_Level  := At_Level;
      This.Truncated := False;
      This.As_Json   := Style_Now = Json;
      This.Active    := Enabled (At_Level) and then 64 + 6 * Message'Length + Line_Close <= This.Capacity;
      if not This.Active then
         return;
      end if;
      if This.As_Json then
         Put (This.Text, This.Last, "{""time"":""");
         Put (This.Text, This.Last, Timestamp);
         Put (This.Text, This.Last, """,""level"":""");
         Put (This.Text, This.Last, Level_Name (At_Level));
         Put (This.Text, This.Last, """,""message"":""");
         Put_Json (This.Text, This.Last, Message);
         Put (This.Text, This.Last, '"');
      else
         Put (This.Text, This.Last, Timestamp);
         Put (This.Text, This.Last, ' ');
         Put (This.Text, This.Last, Level_Columns (At_Level));
         Put_Message (This.Text, This.Last, Message);
      end if;
   end Start;

   --  Whether a field of these sizes surely fits; marks the line truncated when not.
   function Room_For (This : in out Line_Builder; Name_Length, Value_Length : Natural) return Boolean is begin
      if not This.Active then
         return False;
      elsif This.Last + 8 + 6 * (Name_Length + Value_Length) + Line_Close > This.Capacity then
         This.Truncated := True;
         return False;
      end if;
      return True;
   end Room_For;

   procedure Put_Name (This : in out Line_Builder; Name : String) is begin
      if This.As_Json then
         Put (This.Text, This.Last, ",""");
         Put_Json (This.Text, This.Last, Name);
         Put (This.Text, This.Last, """:");
      else
         Put (This.Text, This.Last, ' ');
         Put_Text_Value (This.Text, This.Last, Name);
         Put (This.Text, This.Last, '=');
      end if;
   end Put_Name;

   procedure Add (This : in out Line_Builder; Name : String; Value : String) is begin
      if Room_For (This, Name'Length, Value'Length) then
         Put_Name (This, Name);
         if This.As_Json then
            Put (This.Text, This.Last, '"');
            Put_Json (This.Text, This.Last, Value);
            Put (This.Text, This.Last, '"');
         else
            Put_Text_Value (This.Text, This.Last, Value);
         end if;
      end if;
   end Add;

   procedure Add_Number (This : in out Line_Builder; Name : String; Image : String) is begin
      if Room_For (This, Name'Length, Image'Length) then
         Put_Name (This, Name);
         Put (This.Text, This.Last, Image);
      end if;
   end Add_Number;

   procedure Add (This : in out Line_Builder; Name : String; Value : Long_Long_Integer) is begin
      if This.Active then
         Add_Number (This, Name, Encoding.Decimal_Image (Value));
      end if;
   end Add;

   function Milliseconds_Image (Value : Duration) return String is
      Micro : constant Long_Long_Integer := Long_Long_Integer (Value * 1_000_000);
      Whole : constant String := Encoding.Decimal_Image (abs Micro / 1000);
      Part  : constant String := Encoding.Decimal_Image (abs Micro mod 1000 + 1000);   --  "1xyz"
   begin
      return (if Micro < 0 then "-" else "") & Whole & "." & Part (Part'First + 1 .. Part'Last);
   end Milliseconds_Image;

   procedure Add (This : in out Line_Builder; Name : String; Value : Duration) is begin
      if This.Active then
         Add_Number (This, Name, Milliseconds_Image (Value));
      end if;
   end Add;

   procedure Write_Out (Line : String; Urgent : Boolean);

   procedure Write (This : in out Line_Builder) is
      Target : constant Sink := Sink_Now;
   begin
      if not This.Active then
         return;
      end if;
      This.Active := False;
      if This.Truncated then
         Put (This.Text, This.Last, (if This.As_Json then ",""truncated"":true" else " truncated=true"));
      end if;
      if This.As_Json then
         Put (This.Text, This.Last, '}');
      end if;
      if Target = null then
         Write_Out (This.Text (1 .. This.Last), Urgent => This.At_Level >= Warning);
      else
         Target (This.Text (1 .. This.Last));
      end if;
   end Write;

   ---------------------------------------------------------------------------------------------------------------
   --  batched output to standard error

   Buffered      : Boolean := True with Atomic;
   Dropping      : Boolean := False with Atomic;
   Flush_Every   : Duration := 0.05 with Atomic;

   Shard_Capacity : constant := 16_384;
   Longest_Line   : constant := Shard_Capacity / 2;   --  longer lines are written on their own
   Max_Shards     : constant := 32;

   type Text_Access is access String;   --  a shard's buffers, kept for the program's life

   Dropped_Lines : constant Metrics.Counter :=
     Metrics.New_Counter ("sparrow_log_lines_dropped_total",
                          "Log lines dropped because the output did not keep up (LOG_OVERFLOW=drop).");

   --  Wakes the flusher early, and counts drops not reported yet.
   protected Signal is
      procedure Wake;
      entry Wait;
      procedure Count_Drop;
      procedure Take_Drops (Count : out Natural);
   private
      Woken    : Boolean := False;
      Unwritten : Natural := 0;
   end Signal;

   protected body Signal is
      procedure Wake is begin
         Woken := True;
      end Wake;

      entry Wait when Woken is begin
         Woken := False;
      end Wait;

      procedure Count_Drop is begin
         Unwritten := Unwritten + 1;
      end Count_Drop;

      procedure Take_Drops (Count : out Natural) is begin
         Count     := Unwritten;
         Unwritten := 0;
      end Take_Drops;
   end Signal;

   --  Lines waiting to be written: an active buffer that tasks append to, and a spare the flusher swaps in.
   protected type Shard is
      --  Appended is False when there was no room and the line was not dropped: wait with Append.
      procedure Try_Append (Line : String; Urgent : Boolean; Appended : out Boolean);
      entry Append (Line : String; Urgent : Boolean);
      procedure Take (Full : out Text_Access; Length : out Natural);   --  only under Output
      procedure Give_Back (Spare : Text_Access);
   private
      entry Wait_Room (Line : String; Urgent : Boolean);
      procedure Copy (Line : String; Urgent : Boolean);
      Active : Text_Access;
      Spare  : Text_Access;
      Used   : Natural := 0;
   end Shard;

   protected body Shard is

      --  Wakes the flusher on an urgent line, and once as the buffer passes half full.
      procedure Copy (Line : String; Urgent : Boolean) is
         Before : constant Natural := Used;
      begin
         Active (Used + 1 .. Used + Line'Length) := Line;
         Used := Used + Line'Length + 1;
         Active (Used) := ASCII.LF;
         if Urgent or else (Before <= Shard_Capacity / 2 and then Used > Shard_Capacity / 2) then
            Signal.Wake;
         end if;
      end Copy;

      procedure Try_Append (Line : String; Urgent : Boolean; Appended : out Boolean) is begin
         if Active = null then
            Active := new String (1 .. Shard_Capacity);
            Spare  := new String (1 .. Shard_Capacity);
         end if;
         Appended := True;
         if Used + Line'Length + 1 <= Shard_Capacity then
            Copy (Line, Urgent);
         elsif Dropping then
            Signal.Count_Drop;
            Metrics.Add (Dropped_Lines);
            Signal.Wake;
         else
            Signal.Wake;
            Appended := False;
         end if;
      end Try_Append;

      entry Append (Line : String; Urgent : Boolean) when True is begin
         if Active = null then
            Active := new String (1 .. Shard_Capacity);
            Spare  := new String (1 .. Shard_Capacity);
         end if;
         if Used + Line'Length + 1 <= Shard_Capacity then
            Copy (Line, Urgent);
         elsif Dropping then
            Signal.Count_Drop;
            Metrics.Add (Dropped_Lines);
            Signal.Wake;
         else
            Signal.Wake;
            requeue Wait_Room;
         end if;
      end Append;

      --  Opens once the flusher has swapped the full buffer out; Line is at most half a buffer.
      entry Wait_Room (Line : String; Urgent : Boolean) when Used <= Shard_Capacity / 2 is begin
         Copy (Line, Urgent);
      end Wait_Room;

      procedure Take (Full : out Text_Access; Length : out Natural) is begin
         if Used = 0 or else Spare = null then
            Full   := null;
            Length := 0;
         else
            Full   := Active;
            Length := Used;
            Active := Spare;
            Spare  := null;
            Used   := 0;
         end if;
      end Take;

      procedure Give_Back (Spare : Text_Access) is begin
         Shard.Spare := Spare;
      end Give_Back;

   end Shard;

   --  Kept apart, so that tasks appending to different shards do not share cache lines.
   type Padding is array (1 .. 128) of Character;
   type Separate_Shard is record
      Before : Padding;
      Item   : Shard;
      After  : Padding;
   end record;

   Shard_Table : array (1 .. Max_Shards) of Separate_Shard;
   Shard_Count : Positive := 1;

   --  Each task's shard, chosen on its first line.
   My_Shard : Natural := 0 with Thread_Local_Storage;

   protected Shard_Picker is
      procedure Next (Index : out Positive);
   private
      Last : Natural := 0;
   end Shard_Picker;

   protected body Shard_Picker is
      procedure Next (Index : out Positive) is begin
         Last  := Last mod Shard_Count + 1;
         Index := Last;
      end Next;
   end Shard_Picker;

   --  Held while writing to standard error, so that batches and long lines never mix.
   protected Output is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Output;

   protected body Output is
      entry Seize when not Held is begin
         Held := True;
      end Seize;

      procedure Release is begin
         Held := False;
      end Release;
   end Output;

   --  Every shard's lines out, then a word about lines dropped. Only under Output.
   procedure Write_Shards is
      Full    : Text_Access;
      Length  : Natural;
      Dropped : Natural;
   begin
      for Index in 1 .. Shard_Count loop
         Shard_Table (Index).Item.Take (Full, Length);
         if Full /= null then
            IO.Process.Write_Error (Full (1 .. Length));
            Shard_Table (Index).Item.Give_Back (Full);
         end if;
      end loop;
      Signal.Take_Drops (Dropped);
      if Dropped > 0 then
         IO.Process.Write_Error
           (Format_Line (Warning, "log lines were dropped: the output did not keep up",
                         Field ("count", Long_Long_Integer (Dropped))) & ASCII.LF);
      end if;
   end Write_Shards;

   procedure Flush is begin
      Output.Seize;
      Write_Shards;
      Output.Release;
   end Flush;

   --  Writes the shards out until the main program has finished, then once more.
   task type Flusher;

   task body Flusher is
      use Ada.Task_Identification;
   begin
      loop
         select
            Signal.Wait;
         or
            delay Flush_Every;
         end select;
         Flush;
         exit when not Is_Callable (Environment_Task);
      end loop;
      Flush;
   end Flusher;

   type Flusher_Access is access Flusher;
   Flusher_Started : Boolean := False with Atomic;

   protected Starter is
      procedure Start;
   private
      The_Flusher : Flusher_Access;
   end Starter;

   protected body Starter is
      procedure Start is begin
         if not Flusher_Started then
            The_Flusher     := new Flusher;
            Flusher_Started := True;
         end if;
      end Start;
   end Starter;

   --  Lines a task logs after the flusher has gone (the main program finished first) are written at the end.
   type Last_Flush is new Ada.Finalization.Limited_Controlled with null record;
   overriding procedure Finalize (This : in out Last_Flush);
   overriding procedure Finalize (This : in out Last_Flush) is
      pragma Unreferenced (This);
   begin
      Flush;
   end Finalize;
   At_The_End : Last_Flush with Unreferenced;

   procedure Write_Out (Line : String; Urgent : Boolean) is begin
      if not Buffered then
         IO.Process.Log (Line);
      elsif Line'Length >= Longest_Line then
         --  After the lines already buffered, so that a task's lines stay in order.
         Output.Seize;
         Write_Shards;
         IO.Process.Write_Error (Line & ASCII.LF);
         Output.Release;
      else
         if not Flusher_Started then
            Starter.Start;
         end if;
         if My_Shard = 0 then
            Shard_Picker.Next (My_Shard);
         end if;
         declare
            Appended : Boolean;
         begin
            Shard_Table (My_Shard).Item.Try_Append (Line, Urgent, Appended);
            if not Appended then
               Shard_Table (My_Shard).Item.Append (Line, Urgent);   --  waits for room
            end if;
         end;
      end if;
   end Write_Out;

   procedure Configure_Output
     (Buffered       : Boolean := True;
      Flush_Interval : Duration := 0.05;
      On_Overflow    : Overflow_Policy := Wait)
   is begin
      if not Buffered then
         Flush;
      end if;
      Logs.Buffered := Buffered;
      Flush_Every   := Flush_Interval;
      Dropping      := On_Overflow = Drop;
   end Configure_Output;

   ---------------------------------------------------------------------------------------------------------------

   procedure Log (At_Level : Level; Message : String; Details : Fields := No_Fields) is
      Target : constant Sink := Sink_Now;
      Room   : constant Positive := Worst_Length (Message, Details);
   begin
      if At_Level < Threshold_Now then
         return;
      elsif Target /= null or else Room > 16_384 then
         declare
            Line : constant String := Format_Line (At_Level, Message, Details);
         begin
            if Target = null then
               Write_Out (Line, Urgent => At_Level >= Warning);
            else
               Target (Line);
            end if;
         end;
      else
         declare
            Line : String (1 .. Room);
            Last : Natural;
         begin
            Format_Into (Line, Last, At_Level, Message, Details);
            Write_Out (Line (1 .. Last), Urgent => At_Level >= Warning);
         end;
      end if;
   end Log;

   procedure Debug (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields) is begin
      if Enabled (Logs.Debug) then
         Log (Logs.Debug, Message, First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Debug;

   procedure Info (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields) is begin
      if Enabled (Logs.Info) then
         Log (Logs.Info, Message, First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Info;

   procedure Warning (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields) is begin
      if Enabled (Logs.Warning) then
         Log (Logs.Warning, Message, First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Warning;

   procedure Error (Message : String; First, Second, Third, Fourth, Fifth, Sixth : Fields := No_Fields) is begin
      if Enabled (Logs.Error) then
         Log (Logs.Error, Message, First & Second & Third & Fourth & Fifth & Sixth);
      end if;
   end Error;

begin
   declare
      use Ada.Characters.Handling;
      Wanted_Level    : constant String := To_Lower (IO.Process.Environment ("LOG_LEVEL", Default => "info"));
      Wanted_Format   : constant String := To_Lower (IO.Process.Environment ("LOG_FORMAT", Default => "text"));
      Wanted_Buffer   : constant String := To_Lower (IO.Process.Environment ("LOG_BUFFER", Default => "on"));
      Wanted_Overflow : constant String := To_Lower (IO.Process.Environment ("LOG_OVERFLOW", Default => "wait"));
      Wanted_Interval : constant String := IO.Process.Environment ("LOG_FLUSH_MS");
   begin
      Threshold_Now := (if Wanted_Level = "debug" then Debug
                        elsif Wanted_Level in "warning" | "warn" then Warning
                        elsif Wanted_Level = "error" then Error
                        else Info);
      Style_Now := (if Wanted_Format = "json" then Json else Text);
      Buffered  := Wanted_Buffer /= "off";
      Dropping  := Wanted_Overflow = "drop";
      if Wanted_Interval'Length in 1 .. 5 and then (for all Digit of Wanted_Interval => Digit in '0' .. '9') then
         Flush_Every := Duration (Integer'Max (1, Integer'Min (60_000, Integer'Value (Wanted_Interval)))) / 1000;
      end if;
      Shard_Count := Positive'Max (1, Positive'Min (Max_Shards, IO.Process.Processor_Count));
   end;
end Sparrow.Logs;
