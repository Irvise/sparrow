with Sparrow.Encoding;

package body Sparrow.Json with SPARK_Mode is

   -----------
   -- Parse --
   -----------

   procedure Parse
     (This    : in out Document;
      Source  : String;
      Valid   : out Boolean;
      Options : Parse_Options := Default_Options)
   is
      Next   : Positive := Source'First; --  the next unread character of Source
      Failed : Boolean := False;         --  malformed, or over a capacity: the rest is skipped

      ------------
      -- At_End --
      ------------

      function At_End return Boolean is (Next > Source'Last);

      -------------
      -- Current --
      -------------

      function Current return Character is (Source (Next))
      with Pre => Next in Source'Range;

      ----------------
      -- Sizes_Hold --
      ----------------

      --  The sizes every step keeps within the document's capacities.
      function Sizes_Hold return Boolean is
        (Source'First >= 1 and then Source'Last < Positive'Last and then This.Text_Capacity < Positive'Last
         and then This.Node_Total <= This.Node_Capacity and then This.Text_Length <= This.Text_Capacity
         and then Next <= Source'Last + 1 and then Next >= Source'First);

      ------------
      -- Expect --
      ------------

      procedure Expect (Symbol : Character)
         with Pre => Sizes_Hold, Post => Sizes_Hold and then Next >= Next'Old
      is begin
         if At_End or else Current /= Symbol then
            Failed := True;
         else
            Next := Next + 1;
         end if;
      end Expect;

      ---------------------
      -- Skip_Whitespace --
      ---------------------

      procedure Skip_Whitespace
         with Pre => Sizes_Hold, Post => Sizes_Hold and then Next >= Next'Old
      is begin
         while not At_End and then Current in ' ' | ASCII.HT | ASCII.LF | ASCII.CR loop
            pragma Loop_Invariant (Sizes_Hold and then Next >= Next'Loop_Entry);
            pragma Loop_Variant (Increases => Next);
            Next := Next + 1;
         end loop;
      end Skip_Whitespace;

      ---------
      -- Put --
      ---------

      procedure Put (Symbol : Character)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next = Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
      is begin
         if This.Text_Length >= This.Text_Capacity then
            Failed := True;
         else
            This.Text_Length             := This.Text_Length + 1;
            This.Text (This.Text_Length) := Symbol;
         end if;
      end Put;

      subtype Code_Point is Natural range 0 .. 16#10_FFFF#;

      --------------
      -- Put_Utf8 --
      --------------

      procedure Put_Utf8 (Point : Code_Point)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold 
                      and then Next = Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
      is

         ------------------
         -- Continuation --
         ------------------

         function Continuation (Bits : Natural) return Character is (Character'Val (16#80# + Bits mod 64));
      begin
         case Point is
            when 0 .. 16#7F# =>
               Put (Character'Val (Point));
            when 16#80# .. 16#7FF# =>
               Put (Character'Val (16#C0# + Point / 64));
               Put (Continuation (Point));
            when 16#800# .. 16#FFFF# =>
               Put (Character'Val (16#E0# + Point / 4096));
               Put (Continuation (Point / 64));
               Put (Continuation (Point));
            when others =>
               Put (Character'Val (16#F0# + Point / 262_144));
               Put (Continuation (Point / 4096));
               Put (Continuation (Point / 64));
               Put (Continuation (Point));
         end case;
      end Put_Utf8;

      --------------
      -- Hex_Quad --
      --------------

      --  The four hexadecimal digits of a \u escape.
      procedure Hex_Quad (Result : out Natural)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then Result < 16#1_0000#
      is
         Digit : Natural;
      begin
         Result := 0;
         for Count in 1 .. 4 loop
            pragma Loop_Invariant (Sizes_Hold and then Next >= Next'Loop_Entry and then Result < 16 ** (Count - 1));
            if At_End then
               Failed := True;
               return;
            end if;

            case Current is
               when '0' .. '9' => Digit := Character'Pos (Current) - Character'Pos ('0');
               when 'a' .. 'f' => Digit := Character'Pos (Current) - Character'Pos ('a') + 10;
               when 'A' .. 'F' => Digit := Character'Pos (Current) - Character'Pos ('A') + 10;
               when others =>
                  Failed := True;
                  return;
            end case;

            Result := Result * 16 + Digit;
            Next   := Next + 1;
         end loop;
      end Hex_Quad;

      --------------------
      -- Unicode_Escape --
      --------------------

      --  After a backslash and 'u': one escaped code point, joining a surrogate pair.
      procedure Unicode_Escape
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
      is
         High, Low : Natural;
      begin

         Hex_Quad (High);
         if Failed then
            return;
         end if;

         case High is
            when 16#D800# .. 16#DBFF# =>
               Expect ('\');
               Expect ('u');
               if Failed then
                  return;
               end if;

               Hex_Quad (Low);
               if Failed or else Low not in 16#DC00# .. 16#DFFF# then
                  Failed := True;
                  return;
               end if;

               Put_Utf8 (16#1_0000# + (High - 16#D800#) * 1024 + (Low - 16#DC00#));
            when 16#DC00# .. 16#DFFF# =>
               Failed := True;   --  a lone low surrogate
            when 0 =>
               if Options.Allow_Nul then
                  Put (ASCII.NUL);
               else
                  Failed := True;
               end if;
            when others =>
               Put_Utf8 (High);
         end case;
      end Unicode_Escape;

      ------------------
      -- Parse_String --
      ------------------

      --  At the opening quote: the string's decoded text.
      procedure Parse_String (Result : out Span)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total = This.Node_Total'Old
                      and then (if not Failed then Result.Last <= This.Text_Length)
      is
         First : constant Positive := This.Text_Length + 1;
      begin
         Result := (First => First, Last => First - 1);
         Expect ('"');

         loop
            pragma Loop_Invariant (Sizes_Hold 
                                   and then Next >= Next'Loop_Entry
                                   and then This.Text_Length >= First - 1
                                   and then This.Node_Total = This.Node_Total'Loop_Entry);
            pragma Loop_Variant (Increases => Next);

            if Failed then
               return;
            elsif At_End then
               Failed := True;
               return;
            end if;

            case Current is
               when '"' =>
                  Next := Next + 1;
                  exit;
               when '\' =>
                  Next := Next + 1;
                  if At_End then
                     Failed := True;
                     return;
                  end if;

                  declare
                     Escaped : constant Character := Current;
                  begin
                     Next := Next + 1;
                     case Escaped is
                        when '"' | '\' | '/' => Put (Escaped);
                        when 'b' => Put (ASCII.BS);
                        when 'f' => Put (ASCII.FF);
                        when 'n' => Put (ASCII.LF);
                        when 'r' => Put (ASCII.CR);
                        when 't' => Put (ASCII.HT);
                        when 'u' => Unicode_Escape;
                        when others => Failed := True;
                     end case;
                  end;
               when ASCII.NUL .. Character'Val (31) =>
                  Failed := True;
                  return;
               when others =>
                  Put (Current);
                  Next := Next + 1;
            end case;
         end loop;

         if not Sparrow.Encoding.Valid_Utf8 (This.Text (First .. This.Text_Length)) then
            Failed := True;
            return;
         end if;

         Result := (First => First, Last => This.Text_Length);
      end Parse_String;

      --------------
      -- New_Node --
      --------------

      procedure New_Node (Of_Kind : Kind; Item : out Node_Count)
         with Pre  => Sizes_Hold,
              Post => Sizes_Hold
                      and then Next = Next'Old
                      and then This.Text_Length = This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is begin
         Item := No_Node;
         if This.Node_Total >= This.Node_Capacity then
            Failed := True;
            return;
         end if;

         This.Node_Total              := This.Node_Total + 1;
         This.Nodes (This.Node_Total) := (Of_Kind => Of_Kind, others => <>);
         Item                         := This.Node_Total;
      end New_Node;

      -------------------
      -- Parse_Literal --
      -------------------

      procedure Parse_Literal (Word : String; Of_Kind : Kind; Item : out Node_Count)
         with Pre  => Sizes_Hold
                      and then Word'First = 1
                      and then Word'Length in 1 .. 5,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length = This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is begin
         Item := No_Node;
         if Source'Last - Next + 1 < Word'Length or else Source (Next .. Next + (Word'Length - 1)) /= Word then
            Failed := True;
            return;
         end if;

         Next := Next + Word'Length;
         New_Node (Of_Kind, Item);
      end Parse_Literal;

      ------------------
      -- Parse_Number --
      ------------------

      procedure Parse_Number (Item : out Node_Count)
         with Pre  => Sizes_Hold and then not At_End,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is
         First : constant Positive := This.Text_Length + 1;

         --  Copy the current character into the number's text.
         procedure Take
            with Pre  => Sizes_Hold and then not At_End,
                 Post => Sizes_Hold and then Next > Next'Old and then This.Text_Length >= This.Text_Length'Old
                         and then This.Node_Total = This.Node_Total'Old
         is begin
            Put (Current);
            Next := Next + 1;
         end Take;

         procedure Digits_Run
            with Pre  => Sizes_Hold,
                 Post => Sizes_Hold and then Next >= Next'Old and then This.Text_Length >= This.Text_Length'Old
                         and then This.Node_Total = This.Node_Total'Old
         is begin
            while not Failed and then not At_End and then Current in '0' .. '9' loop
               pragma Loop_Invariant
                 (Sizes_Hold and then Next >= Next'Loop_Entry and then This.Text_Length >= This.Text_Length'Loop_Entry
                  and then This.Node_Total = This.Node_Total'Loop_Entry);
               pragma Loop_Variant (Increases => Next);
               Take;
            end loop;
         end Digits_Run;
      begin
         New_Node (Number_Kind, Item);
         if Failed then
            return;
         end if;

         if Current = '-' then
            Take;
         end if;

         --  the integer part: 0, or a digit other than 0 and then any digits
         if At_End or else Current not in '0' .. '9' then
            Failed := True;
            return;
         elsif Current = '0' then
            Take;
         else
            Digits_Run;
         end if;

         if not Failed and then not At_End and then Current = '.' then
            Take;
            if At_End or else Current not in '0' .. '9' then
               Failed := True;
               return;
            end if;
            Digits_Run;
         end if;

         if not Failed and then not At_End and then Current in 'e' | 'E' then
            Take;
            if not At_End and then Current in '+' | '-' then
               Take;
            end if;
            if At_End or else Current not in '0' .. '9' then
               Failed := True;
               return;
            end if;
            Digits_Run;
         end if;

         if Failed then
            return;
         end if;

         This.Nodes (Item).Value := (First => First, Last => This.Text_Length);
      end Parse_Number;

      -----------------
      -- Parse_Value --
      -----------------

      --  One value and, for arrays and objects, everything inside it.
      procedure Parse_Value (Depth : Natural; Item : out Node_Count)
         with Subprogram_Variant => (Decreases => Max_Depth - Depth),
              Pre  => Sizes_Hold and then Depth <= Max_Depth,
              Post => Sizes_Hold
                      and then Next >= Next'Old
                      and then This.Text_Length >= This.Text_Length'Old
                      and then This.Node_Total >= This.Node_Total'Old
                      and then (if not Failed then Item in 1 .. This.Node_Total)
      is
         Closing  : Character;
         Previous : Node_Count := No_Node;
         Child    : Node_Count;
         Key      : Span;
      begin
         Item := No_Node;
         Skip_Whitespace;
         if Failed or else At_End then
            Failed := True;
            return;
         end if;

         case Current is
            when '{' | '[' =>
               Closing := (if Current = '{' then '}' else ']');
               New_Node ((if Closing = '}' then Object_Kind else Array_Kind), Item);
               if Failed then
                  return;
               end if;

               Next := Next + 1;   --  the opening bracket
               Skip_Whitespace;
               if not At_End and then Current = Closing then
                  Next := Next + 1;
                  return;
               end if;

               loop
                  pragma Loop_Invariant
                    (Sizes_Hold and then Next >= Next'Loop_Entry and then Item in 1 .. This.Node_Total
                     and then Previous <= This.Node_Total and then This.Text_Length >= This.Text_Length'Loop_Entry
                     and then This.Node_Total >= This.Node_Total'Loop_Entry);
                  pragma Loop_Variant (Increases => Next);
                  if Depth = Max_Depth then
                     Failed := True;   --  nested too deeply
                     return;
                  end if;

                  Key := (First => 1, Last => 0);
                  if Closing = '}' then
                     Skip_Whitespace;
                     Parse_String (Key);
                     Skip_Whitespace;
                     Expect (':');
                     if Failed then
                        return;
                     end if;
                  end if;

                  Parse_Value (Depth + 1, Child);
                  if Failed then
                     return;
                  end if;

                  This.Nodes (Child).Key := Key;
                  if Previous = No_Node then
                     This.Nodes (Item).First_Child := Child;
                  else
                     This.Nodes (Previous).Next_Sibling := Child;
                  end if;
                  Previous := Child;

                  Skip_Whitespace;
                  if At_End then
                     Failed := True;
                     return;
                  elsif Current = Closing then
                     Next := Next + 1;
                     return;
                  elsif Current /= ',' then
                     Failed := True;
                     return;
                  end if;

                  Next := Next + 1;
                  end loop;
            when '"' =>
               New_Node (String_Kind, Item);
               if Failed then
                  return;
               end if;
               Parse_String (Key);
               if not Failed then
                  This.Nodes (Item).Value := Key;
               end if;
            when 't' =>
               Parse_Literal ("true", True_Kind, Item);
            when 'f' =>
               Parse_Literal ("false", False_Kind, Item);
            when 'n' =>
               Parse_Literal ("null", Null_Kind, Item);
            when '-' | '0' .. '9' =>
               Parse_Number (Item);
            when others =>
               Failed := True;
         end case;
      end Parse_Value;

      Top : Node_Count;
   begin
      Valid := False;
      This.Parsed := False;
      if Source'Length = 0 then
         return;
      end if;

      This.Node_Total  := 0;
      This.Text_Length := 0;
      Parse_Value (0, Top);
      Skip_Whitespace;
      Valid := not Failed and then At_End and then Top = Root;
      This.Parsed := Valid;
   end Parse;

   ------------
   -- Exists --
   ------------

   function Exists (This : Document; Item : Node_Count) return Boolean is
     (Item /= No_Node and then Item <= This.Node_Total and then Item <= This.Node_Capacity);

   -------------
   -- Text_Of --
   -------------

   --  The text a span names, or "" when it is empty or outside the document's text.
   function Text_Of (This : Document; Item : Span) return String is
     (if Item.Last < Item.First
         or else Item.Last > This.Text_Length
         or else Item.Last > This.Text_Capacity
      then ""
      else This.Text (Item.First .. Item.Last));

   -------------
   -- Kind_Of --
   -------------

   function Kind_Of (This : Document; Item : Node_Count) return Kind is
     (if Exists (This, Item) then This.Nodes (Item).Of_Kind else Null_Kind);

   -----------
   -- Value --
   -----------

   --  The bare conversions below are sound: the document's text is only ever written by Parse, which accepts
   --  a string only once Valid_Utf8 has passed it, and writes numbers as ASCII.
   function Value (This : Document; Item : Node_Count) return UTF8_String is
     (if Exists (This, Item) then UTF8_String (Text_Of (This, This.Nodes (Item).Value)) else "");

   ----------
   -- Name --
   ----------

   function Name (This : Document; Item : Node_Count) return UTF8_String is
     (if Exists (This, Item) then UTF8_String (Text_Of (This, This.Nodes (Item).Key)) else "");

   -------------------
   -- Boolean_Value --
   -------------------

   function Boolean_Value (This : Document; Item : Node_Count) return Boolean is (Kind_Of (This, Item) = True_Kind);

   -----------------
   -- Get_Integer --
   -----------------

   procedure Get_Integer (This : Document; Item : Node_Count; Value : out Long_Long_Integer; Valid : out Boolean) is
   begin
      if Kind_Of (This, Item) = Number_Kind then
         Sparrow.Encoding.Parse_Decimal (Text_Of (This, This.Nodes (Item).Value), Value, Valid);
      else
         Value := 0;
         Valid := False;
      end if;
   end Get_Integer;

   ---------------
   -- Get_Float --
   ---------------

   --  The text was checked against JSON's number grammar by Parse, which is within what 'Value reads; what
   --  'Value can still refuse is a magnitude Long_Float cannot hold.
   procedure Convert (Image : String; Value : out Long_Float; Valid : out Boolean);
   procedure Convert (Image : String; Value : out Long_Float; Valid : out Boolean) with SPARK_Mode => Off is
   begin
      Value := Long_Float'Value (Image);
      Valid := True;
   exception
      when Constraint_Error =>
         Value := 0.0;
         Valid := False;
   end Convert;

   procedure Get_Float (This : Document; Item : Node_Count; Value : out Long_Float; Valid : out Boolean) is begin
      if Kind_Of (This, Item) = Number_Kind and then This.Nodes (Item).Value.First <= This.Nodes (Item).Value.Last
      then
         Convert (Text_Of (This, This.Nodes (Item).Value), Value, Valid);
         if not Valid then
            Value := 0.0;
         end if;
      else
         Value := 0.0;
         Valid := False;
      end if;
   end Get_Float;

   -----------------
   -- First_Child --
   -----------------

   --  Links only ever point forward to nodes parsed later; anything else reads as no node.
   function First_Child (This : Document; Item : Node_Count) return Node_Count is
     (if Exists (This, Item)
         and then This.Nodes (Item).First_Child > Item
      then This.Nodes (Item).First_Child
      else No_Node);

   ------------------
   -- Next_Sibling --
   ------------------

   function Next_Sibling (This : Document; Item : Node_Count) return Node_Count is
     (if Exists (This, Item)
         and then This.Nodes (Item).Next_Sibling > Item
      then This.Nodes (Item).Next_Sibling
      else No_Node);

   ------------
   -- Member --
   ------------

   -----------------
   -- Child_Count --
   -----------------

   function Child_Count (This : Document; Item : Node_Count) return Natural is
      Child : Node_Count := First_Child (This, Item);
      Count : Natural := 0;
   begin
      while Exists (This, Child) and then Count < Natural (Node_Count'Last) loop
         pragma Loop_Variant (Increases => Child);
         pragma Loop_Invariant (Count < Natural (Node_Count'Last));
         Count := Count + 1;
         Child := Next_Sibling (This, Child);
      end loop;
      return Count;
   end Child_Count;

   ------------
   -- Member --
   ------------

   function Member (This : Document; Object : Node_Count; Name : UTF8_String) return Node_Count is
      Child : Node_Count;
   begin
      if Kind_Of (This, Object) /= Object_Kind then
         return No_Node;
      end if;
      Child := First_Child (This, Object);
      while Exists (This, Child) loop
         pragma Loop_Variant (Increases => Child);
         if Text_Of (This, This.Nodes (Child).Key) = String (Name) then
            return Child;
         end if;
         Child := Next_Sibling (This, Child);
      end loop;
      return No_Node;
   end Member;

   -------------
   -- Element --
   -------------

   function Element (This : Document; List : Node_Count; Position : Natural) return Node_Count is
      Child : Node_Count;
      Left  : Natural := Position;
   begin
      if Kind_Of (This, List) /= Array_Kind then
         return No_Node;
      end if;
      Child := First_Child (This, List);
      while Exists (This, Child) loop
         pragma Loop_Variant (Increases => Child);
         pragma Loop_Invariant (Child > List);
         if Left = 0 then
            return Child;
         end if;
         Left := Left - 1;
         Child := Next_Sibling (This, Child);
      end loop;
      return No_Node;
   end Element;

   ----------
   -- Find --
   ----------

   --  One step of a path from Current: an element position in an array, otherwise a member name.
   function Step (This : Document; Current : Node_Count; Name : UTF8_String) return Node_Count is
      Position : Natural := 0;
   begin
      if Name'Length = 0 then
         return No_Node;
      end if;
      if Kind_Of (This, Current) = Array_Kind
        and then Name'Length <= 9
        and then (for all Symbol of Name => Symbol in '0' .. '9')
      then
         for Symbol of Name loop
            pragma Loop_Invariant (Position < 10 ** 8);
            Position := Position * 10 + (Character'Pos (Symbol) - Character'Pos ('0'));
            exit when Position >= 10 ** 8;   --  longer than any document can be
         end loop;
         return Element (This, Current, Position);
      end if;
      return Member (This, Current, Name);
   end Step;

   function Find (This : Document; Path : UTF8_String; From : Node_Count := Root) return Node_Count is
      Current : Node_Count := (if Exists (This, From) then From else No_Node);
      Start   : Positive;
   begin
      if Path'Length = 0 or else Current = No_Node then
         return Current;
      elsif Path (Path'Last) = '.' then
         return No_Node;
      end if;
      Start := Path'First;   --  only now: an empty string's bounds need not be Positive
      for Index in Path'Range loop
         pragma Loop_Invariant (Start in Path'First .. Index);
         if Path (Index) = '.' or else Index = Path'Last then
            Current := Step (This, Current, Path (Start .. (if Path (Index) = '.' then Index - 1 else Index)));
            if Current = No_Node then
               return No_Node;
            end if;
            if Index < Path'Last then
               Start := Index + 1;
            end if;
         end if;
      end loop;
      return Current;
   end Find;

   -----------------------
   -- Accessors by path --
   -----------------------

   function Text
     (This : Document; Path : UTF8_String; Default : UTF8_String := ""; From : Node_Count := Root)
      return UTF8_String
   is
      Item : constant Node_Count := Find (This, Path, From);
   begin
      return (if Kind_Of (This, Item) = String_Kind then Value (This, Item) else Default);
   end Text;

   function Integer_Value
     (This : Document; Path : UTF8_String; Default : Long_Long_Integer := 0; From : Node_Count := Root)
      return Long_Long_Integer
   is
      Result : Long_Long_Integer;
      Valid  : Boolean;
   begin
      Get_Integer (This, Find (This, Path, From), Result, Valid);
      return (if Valid then Result else Default);
   end Integer_Value;

   --  Outside SPARK as Get_Float's conversion is: a function must be shown to end, and 'Value is not analysed.
   function Float_Value
     (This : Document; Path : UTF8_String; Default : Long_Float := 0.0; From : Node_Count := Root)
      return Long_Float
     with SPARK_Mode => Off
   is
      Result : Long_Float;
      Valid  : Boolean;
   begin
      Get_Float (This, Find (This, Path, From), Result, Valid);
      return (if Valid then Result else Default);
   end Float_Value;

   function Boolean_Value
     (This : Document; Path : UTF8_String; Default : Boolean := False; From : Node_Count := Root) return Boolean
   is
      Item : constant Node_Count := Find (This, Path, From);
   begin
      return (case Kind_Of (This, Item) is
                 when True_Kind  => True,
                 when False_Kind => False,
                 when others     => Default);
   end Boolean_Value;

   function Length (This : Document; Path : UTF8_String := ""; From : Node_Count := Root) return Natural is
      Item : constant Node_Count := Find (This, Path, From);
   begin
      return (if Kind_Of (This, Item) in Array_Kind | Object_Kind then Child_Count (This, Item) else 0);
   end Length;

   -----------
   -- Rules --
   -----------

   function Make_Rule
     (Path        : UTF8_String;
      Needed      : Boolean;
      Of_Shape    : Shape;
      Shortest    : Natural;
      Longest     : Natural;
      Least, Most : Long_Long_Integer) return Rule
      with Pre => Path'Length <= Max_Rule_Path
   is
      Result : Rule := (Needed => Needed, Of_Shape => Of_Shape, Shortest => Shortest, Longest => Longest,
                        Least => Least, Most => Most, Path_Length => Path'Length, others => <>);
   begin
      Result.Path (1 .. Path'Length) := String (Path);
      return Result;
   end Make_Rule;

   function Required
     (Path     : UTF8_String;
      Of_Shape : Shape;
      Shortest : Natural := 0;
      Longest  : Natural := Natural'Last;
      Least    : Long_Long_Integer := Long_Long_Integer'First;
      Most     : Long_Long_Integer := Long_Long_Integer'Last) return Rule
   is (Make_Rule (Path, True, Of_Shape, Shortest, Longest, Least, Most));

   function Optional
     (Path     : UTF8_String;
      Of_Shape : Shape;
      Shortest : Natural := 0;
      Longest  : Natural := Natural'Last;
      Least    : Long_Long_Integer := Long_Long_Integer'First;
      Most     : Long_Long_Integer := Long_Long_Integer'Last) return Rule
   is (Make_Rule (Path, False, Of_Shape, Shortest, Longest, Least, Most));

   function Shape_Name (Of_Shape : Shape) return String is
     (case Of_Shape is
         when Text_Shape    => "text",
         when Number_Shape  => "a number",
         when Integer_Shape => "an integer",
         when Boolean_Shape => "true or false",
         when Array_Shape   => "an array",
         when Object_Shape  => "an object",
         when Any_Shape     => "a value");

   function Fits (This : Document; Item : Node_Count; Of_Shape : Shape) return Boolean is
      Number : Long_Long_Integer;
      Whole  : Boolean;
   begin
      case Of_Shape is
         when Text_Shape    => return Kind_Of (This, Item) = String_Kind;
         when Number_Shape  => return Kind_Of (This, Item) = Number_Kind;
         when Integer_Shape =>
            pragma Warnings (GNATprove, Off, "*is set by*but not used*", Reason => "only whether it fits matters");
            Get_Integer (This, Item, Number, Whole);
            pragma Warnings (GNATprove, On, "*is set by*but not used*");
            return Whole;
         when Boolean_Shape => return Kind_Of (This, Item) in True_Kind | False_Kind;
         when Array_Shape   => return Kind_Of (This, Item) = Array_Kind;
         when Object_Shape  => return Kind_Of (This, Item) = Object_Kind;
         when Any_Shape     => return True;
      end case;
   end Fits;

   function Image (Value : Natural) return String is
     (Sparrow.Encoding.Decimal_Image (Long_Long_Integer (Value)))
      with Post => Image'Result'Length <= 20;

   --  "must be from 1 to 100", "must be at least 1", "must be at most 100".
   function Range_Problem (Rule_Of : Rule) return String is
     (if Rule_Of.Most = Long_Long_Integer'Last
      then "must be at least " & Sparrow.Encoding.Decimal_Image (Rule_Of.Least)
      elsif Rule_Of.Least = Long_Long_Integer'First
      then "must be at most " & Sparrow.Encoding.Decimal_Image (Rule_Of.Most)
      else "must be from " & Sparrow.Encoding.Decimal_Image (Rule_Of.Least) & " to "
           & Sparrow.Encoding.Decimal_Image (Rule_Of.Most))
      with Post => Range_Problem'Result'Length <= 100;

   --  "must be 1 to 200 bytes", "must have at most 10 elements".
   function Bounds_Problem (Rule_Of : Rule) return String
      with Post => Bounds_Problem'Result'Length <= 100
   is
      Unit : constant String :=
        (case Rule_Of.Of_Shape is
            when Text_Shape  => " byte",
            when Array_Shape => " element",
            when others      => " member");

      function Units (Count : Natural) return String is (Image (Count) & Unit & (if Count = 1 then "" else "s"))
         with Post => Units'Result'Length <= 30;
   begin
      if Rule_Of.Longest = Natural'Last then
         return "must have at least " & Units (Rule_Of.Shortest);
      elsif Rule_Of.Shortest = 0 then
         return "must have at most " & Units (Rule_Of.Longest);
      else
         return "must have " & Image (Rule_Of.Shortest) & " to " & Units (Rule_Of.Longest);
      end if;
   end Bounds_Problem;

   function Problem (This : Document; Rules : Rule_List; From : Node_Count := Root) return UTF8_String is
   begin
      if Kind_Of (This, From) /= Object_Kind then
         return "the body must be a JSON object";
      end if;
      for Checked of Rules loop
         declare
            Path : constant UTF8_String := UTF8_String (Checked.Path (1 .. Checked.Path_Length));
            Item : constant Node_Count := Find (This, Path, From);
            Size : Natural;
         begin
            if Item = No_Node or else (Kind_Of (This, Item) = Null_Kind and then Checked.Of_Shape /= Any_Shape)
            then
               if Checked.Needed then
                  return Path & ": required";
               end if;
            elsif not Fits (This, Item, Checked.Of_Shape) then
               return Path & ": must be " & UTF8_String (Shape_Name (Checked.Of_Shape));
            elsif Checked.Of_Shape = Integer_Shape then
               declare
                  Number : Long_Long_Integer;
                  Whole  : Boolean;
               begin
                  Get_Integer (This, Item, Number, Whole);
                  if Whole and then (Number < Checked.Least or else Number > Checked.Most) then
                     return Path & ": " & UTF8_String (Range_Problem (Checked));
                  end if;
               end;
            elsif Checked.Of_Shape in Text_Shape | Array_Shape | Object_Shape then
               Size := (if Checked.Of_Shape = Text_Shape then Value (This, Item)'Length
                        else Child_Count (This, Item));
               if Size < Checked.Shortest or else Size > Checked.Longest then
                  return Path & ": " & UTF8_String (Bounds_Problem (Checked));
               end if;
            end if;
         end;
      end loop;
      return "";
   end Problem;

end Sparrow.Json;
