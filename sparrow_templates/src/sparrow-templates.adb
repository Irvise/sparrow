with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with Sparrow.Encoding;

package body Sparrow.Templates is

   procedure Free is new Ada.Unchecked_Deallocation (Operation_List, Operation_List_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Template, Template_Access);
   procedure Free is new Ada.Unchecked_Deallocation (Named_Template_List, Named_Template_List_Access);

   Max_Section_Depth : constant := 100;   --  sections nested in one template
   Max_Stack_Depth   : constant := 256;   --  scopes entered while rendering, partials included

   ---------------------------------------------------------------------------------------------------------------
   --  compiling

   procedure Add_Operation (This : in out Template; Item : Operation) is begin
      if This.Operations = null or else This.Operation_Total = This.Operations'Last then
         declare
            Larger : constant Operation_List_Access :=
              new Operation_List (1 .. (if This.Operations = null then 64 else 2 * This.Operations'Last));
         begin
            if This.Operations /= null then
               Larger (1 .. This.Operation_Total) := This.Operations (1 .. This.Operation_Total);
               Free (This.Operations);
            end if;
            This.Operations := Larger;
         end;
      end if;
      This.Operation_Total := This.Operation_Total + 1;
      This.Operations (This.Operation_Total) := Item;
   end Add_Operation;

   function Is_Blank (Symbol : Character) return Boolean is (Symbol in ' ' | ASCII.HT);

   procedure Compile (This : in out Template; Source : String; Valid : out Boolean) is
      Open_Sections : array (1 .. Max_Section_Depth) of Positive;   --  their operations
      Open_Tags     : array (1 .. Max_Section_Depth) of Positive;   --  where their tags start
      Open_Total    : Natural := 0;
      Position      : Positive;
      Literal_First : Positive;

      --  Fail at Where (a position in Source, counted from 1).
      procedure Refuse (Where : Positive) is begin
         This.Error_At := Where;
         Valid         := False;
      end Refuse;

      --  Source (First .. Last) as a literal operation, unless empty.
      procedure Add_Literal (First : Positive; Last : Natural) is begin
         if Last >= First then
            Add_Operation (This, (Kind => Literal, First => First, Last => Last, Partner => 0));
         end if;
      end Add_Literal;

   begin
      Free (This);
      Valid := True;
      if not Encoding.Valid_Utf8 (Source) then
         This.Error_At := 1;
         Valid         := False;
         return;
      end if;

      This.Source := new String (1 .. Source'Length);
      This.Source.all := Source;

      declare
         S : String renames This.Source.all;
      begin
         Position      := 1;
         Literal_First := 1;
         while Position <= S'Last - 1 loop
            if S (Position .. Position + 1) /= "{{" then
               Position := Position + 1;
            else
               declare
                  Tag_First : constant Positive := Position;
                  Triple    : constant Boolean := Position + 2 <= S'Last and then S (Position + 2) = '{';
                  Closing   : constant String := (if Triple then "}}}" else "}}");
                  Inner     : constant Positive := Position + (if Triple then 3 else 2);
                  Tag_Last  : Natural := 0;   --  the last character of the closing braces
                  Sigil     : Character := ' ';
                  Kind      : Operation_Kind;
                  Name_First : Positive;
                  Name_Last  : Natural;
                  Standalone : Boolean;
                  Line_First : Positive;      --  where the tag's line starts
                  After      : Positive;      --  past the tag, and past its line when standalone
               begin
                  for Scan in Inner .. S'Last - Closing'Length + 1 loop
                     if S (Scan .. Scan + Closing'Length - 1) = Closing then
                        Tag_Last := Scan + Closing'Length - 1;
                        exit;
                     end if;
                  end loop;
                  if Tag_Last = 0 then
                     Refuse (Tag_First);
                     return;
                  end if;

                  Name_First := Inner;
                  Name_Last  := Tag_Last - Closing'Length;
                  if not Triple and then Name_First <= Name_Last
                    and then S (Name_First) in '#' | '^' | '/' | '!' | '>' | '&' | '='
                  then
                     Sigil      := S (Name_First);
                     Name_First := Name_First + 1;
                  end if;
                  if Sigil = '=' then
                     Refuse (Tag_First);   --  changing the delimiters is not supported
                     return;
                  end if;
                  while Name_First <= Name_Last and then Is_Blank (S (Name_First)) loop
                     Name_First := Name_First + 1;
                  end loop;
                  while Name_Last >= Name_First and then Is_Blank (S (Name_Last)) loop
                     Name_Last := Name_Last - 1;
                  end loop;
                  if Sigil /= '!' and then Name_Last < Name_First then
                     Refuse (Tag_First);   --  a tag without a name
                     return;
                  end if;

                  Kind := (case Sigil is
                              when '#'       => Section_Open,
                              when '^'       => Inverted_Open,
                              when '/'       => Section_Close,
                              when '>'       => Partial,
                              when '&'       => Raw_Variable,
                              when '!'       => Literal,   --  a comment: nothing is added
                              when others    => (if Triple then Raw_Variable else Variable));

                  --  A section, comment or partial tag alone on its line takes the line with it.
                  Line_First := Tag_First;
                  while Line_First > Literal_First and then Is_Blank (S (Line_First - 1)) loop
                     Line_First := Line_First - 1;
                  end loop;
                  After := Tag_Last + 1;
                  while After <= S'Last and then Is_Blank (S (After)) loop
                     After := After + 1;
                  end loop;
                  Standalone := Sigil in '#' | '^' | '/' | '!' | '>'
                    and then (Line_First = 1 or else S (Line_First - 1) = ASCII.LF)
                    and then (After > S'Last or else S (After) = ASCII.LF
                              or else (S (After) = ASCII.CR and then After < S'Last
                                       and then S (After + 1) = ASCII.LF));
                  if Standalone then
                     After := (if After > S'Last then After elsif S (After) = ASCII.CR then After + 2 else After + 1);
                     Add_Literal (Literal_First, Line_First - 1);
                  else
                     After := Tag_Last + 1;
                     Add_Literal (Literal_First, Tag_First - 1);
                  end if;

                  case Kind is
                     when Literal =>
                        null;
                     when Section_Open | Inverted_Open =>
                        if Open_Total = Open_Sections'Last then
                           Refuse (Tag_First);
                           return;
                        end if;
                        Add_Operation (This, (Kind => Kind, First => Name_First, Last => Name_Last, Partner => 0));
                        Open_Total                 := Open_Total + 1;
                        Open_Sections (Open_Total) := This.Operation_Total;
                        Open_Tags (Open_Total)     := Tag_First;
                     when Section_Close =>
                        if Open_Total = 0
                          or else S (This.Operations (Open_Sections (Open_Total)).First
                                     .. This.Operations (Open_Sections (Open_Total)).Last)
                             /= S (Name_First .. Name_Last)
                        then
                           Refuse (Tag_First);   --  closed under another name, or never opened
                           return;
                        end if;
                        Add_Operation (This, (Kind    => Section_Close, First => Name_First, Last => Name_Last,
                                              Partner => Open_Sections (Open_Total)));
                        This.Operations (Open_Sections (Open_Total)).Partner := This.Operation_Total;
                        Open_Total := Open_Total - 1;
                     when others =>
                        Add_Operation (This, (Kind => Kind, First => Name_First, Last => Name_Last, Partner => 0));
                  end case;

                  Position      := After;
                  Literal_First := After;
               end;
            end if;
         end loop;
         Add_Literal (Literal_First, S'Last);

         if Open_Total > 0 then
            Refuse (Open_Tags (Open_Total));   --  never closed
         end if;
      end;
   end Compile;

   function Error_Position (This : Template) return Natural is (This.Error_At);

   procedure Free (This : in out Template) is begin
      Free (This.Source);
      Free (This.Operations);
      This.Operation_Total := 0;
      This.Error_At        := 0;
   end Free;

   ---------------------------------------------------------------------------------------------------------------
   --  rendering

   procedure Append_Html_Escaped (To : in out Buffer; Text : UTF8_String) is
      Run_First : Positive := Text'First;   --  characters that need no escape are appended in runs
   begin
      for Position in Text'Range loop
         declare
            Replacement : constant String :=
              (case Text (Position) is
                  when '&'    => "&amp;",
                  when '<'    => "&lt;",
                  when '>'    => "&gt;",
                  when '"'    => "&quot;",
                  when '''    => "&#39;",
                  when others => "");
         begin
            if Replacement'Length > 0 then
               Append_Text (To, Text (Run_First .. Position - 1));
               Append (To, Replacement);
               Run_First := Position + 1;
            end if;
         end;
      end loop;
      Append_Text (To, Text (Run_First .. Text'Last));
   end Append_Html_Escaped;

   type Scope_Stack is array (1 .. Max_Stack_Depth) of Scope;

   --  Where a name leads: its kind, and the scope and single name to ask the data source about it.
   type Resolution is record
      Kind  : Value_Kind := Absent;
      Where : Scope := 0;
      First : Positive := 1;   --  the last part of the name, in the template's source
      Last  : Natural := 0;
   end record;

   --  Resolve Source (First .. Last), a name, against the scopes Stack (1 .. Depth): its first part in the
   --  innermost scope that has it, every further part inside the object before it.
   function Resolve
     (Data   : Data_Source'Class;
      Source : String;
      First  : Positive;
      Last   : Natural;
      Stack  : Scope_Stack;
      Depth  : Positive) return Resolution
   is
      --  The template compiled from UTF-8 source, and names end at ASCII delimiters: a name is UTF-8 too.
      function Name (From, To : Natural) return UTF8_String is (UTF8_String (Source (From .. To)));

      Dot      : Natural := 0;
      Result   : Resolution;
      Part     : Positive;
   begin
      if Source (First .. Last) = "." then
         return (Kind => Data.Kind_Of (Stack (Depth), "."), Where => Stack (Depth), First => First, Last => Last);
      end if;

      for Position in First .. Last loop
         if Source (Position) = '.' then
            Dot := Position;
            exit;
         end if;
      end loop;

      --  The first part, from the innermost scope outward.
      Result := (Kind => Absent, Where => Stack (Depth), First => First, Last => (if Dot = 0 then Last else Dot - 1));
      for Level in reverse 1 .. Depth loop
         Result.Kind := Data.Kind_Of (Stack (Level), Name (Result.First, Result.Last));
         if Result.Kind /= Absent then
            Result.Where := Stack (Level);
            exit;
         end if;
      end loop;

      --  Every further part: inside the object the part before it named.
      Part := (if Dot = 0 then Last + 1 else Dot + 1);
      while Part <= Last loop
         if Result.Kind /= Object then
            return (others => <>);
         end if;
         Result.Where := Data.Item (Result.Where, Name (Result.First, Result.Last), 1);
         Dot := Part;
         while Dot <= Last and then Source (Dot) /= '.' loop
            Dot := Dot + 1;
         end loop;
         Result.First := Part;
         Result.Last  := Dot - 1;
         Result.Kind  := Data.Kind_Of (Result.Where, Name (Result.First, Result.Last));
         Part := Dot + 1;
      end loop;
      return Result;
   end Resolve;

   procedure Render_Template
     (This    : Template;
      Partials : access constant Library;
      Data    : Data_Source'Class;
      Stack   : in out Scope_Stack;
      Depth   : Positive;
      Into    : in out Buffer;
      Nesting : Natural);

   function Find (This : Library; Name : String) return Template_Access is begin
      for Index in 1 .. This.Total loop
         if This.Items (Index).Name.all = Name then
            return This.Items (Index).Item;
         end if;
      end loop;
      return null;
   end Find;

   --  Render the operations From .. To of This.
   procedure Render_Range
     (This     : Template;
      From, To : Natural;
      Partials : access constant Library;
      Data     : Data_Source'Class;
      Stack    : in out Scope_Stack;
      Depth    : Positive;
      Into     : in out Buffer;
      Nesting  : Natural)
   is
      S     : String renames This.Source.all;
      Index : Natural := From;
   begin
      while Index <= To loop
         declare
            Item : constant Operation := This.Operations (Index);
         begin
            case Item.Kind is
               when Literal =>
                  Append (Into, S (Item.First .. Item.Last));
                  Index := Index + 1;

               when Variable | Raw_Variable =>
                  declare
                     Found : constant Resolution := Resolve (Data, S, Item.First, Item.Last, Stack, Depth);
                     Value : Buffer;
                  begin
                     case Found.Kind is
                        when Scalar =>
                           if Item.Kind = Raw_Variable then
                              Data.Append_Value (Found.Where, UTF8_String (S (Found.First .. Found.Last)), Into);
                           else
                              Data.Append_Value (Found.Where, UTF8_String (S (Found.First .. Found.Last)), Value);
                              --  What a data source appends is text: Append_Value takes and gives UTF-8.
                              Append_Html_Escaped (Into, UTF8_String (Content (Value)));
                              Free (Value);
                           end if;
                        when True_Value =>
                           Append (Into, "true");
                        when others =>
                           null;
                     end case;
                  end;
                  Index := Index + 1;

               when Section_Open | Inverted_Open =>
                  declare
                     Found : constant Resolution := Resolve (Data, S, Item.First, Item.Last, Stack, Depth);
                     Name  : constant UTF8_String := UTF8_String (S (Found.First .. Found.Last));
                     Count : constant Natural :=
                       (if Found.Kind in List | Object then Data.Item_Count (Found.Where, Name) else 0);
                     Empty : constant Boolean :=
                       Found.Kind in Absent | False_Value or else (Found.Kind = List and then Count = 0);
                  begin
                     if Item.Kind = Inverted_Open then
                        if Empty then
                           Render_Range (This, Index + 1, Item.Partner - 1, Partials, Data, Stack, Depth, Into,
                                         Nesting);
                        end if;
                     elsif not Empty then
                        if Found.Kind in List | Object and then Depth < Stack'Last then
                           for Number in 1 .. Count loop
                              Stack (Depth + 1) := Data.Item (Found.Where, Name, Number);
                              Render_Range (This, Index + 1, Item.Partner - 1, Partials, Data, Stack, Depth + 1, Into,
                                            Nesting);
                           end loop;
                        elsif Found.Kind in True_Value | Scalar then
                           Render_Range (This, Index + 1, Item.Partner - 1, Partials, Data, Stack, Depth, Into,
                                         Nesting);
                        end if;
                     end if;
                  end;
                  Index := Item.Partner + 1;

               when Section_Close =>
                  Index := Index + 1;   --  never reached: sections are skipped whole

               when Partial =>
                  if Partials /= null and then Nesting < Max_Partial_Depth then
                     declare
                        Included : constant Template_Access := Find (Partials.all, S (Item.First .. Item.Last));
                     begin
                        if Included /= null then
                           Render_Template (Included.all, Partials, Data, Stack, Depth, Into, Nesting + 1);
                        end if;
                     end;
                  end if;
                  Index := Index + 1;
            end case;
         end;
      end loop;
   end Render_Range;

   procedure Render_Template
     (This     : Template;
      Partials : access constant Library;
      Data     : Data_Source'Class;
      Stack    : in out Scope_Stack;
      Depth    : Positive;
      Into     : in out Buffer;
      Nesting  : Natural)
   is begin
      if This.Source /= null and then This.Error_At = 0 and then This.Operation_Total > 0 then
         Render_Range (This, 1, This.Operation_Total, Partials, Data, Stack, Depth, Into, Nesting);
      end if;
   end Render_Template;

   procedure Render (This : Template; Data : Data_Source'Class; Into : in out Buffer) is
      Stack : Scope_Stack := [1 => Data.Top, others => 0];
   begin
      Render_Template (This, null, Data, Stack, 1, Into, 0);
   end Render;

   ---------------------------------------------------------------------------------------------------------------
   --  libraries

   procedure Add (This : in out Library; Name : UTF8_String; Source : String; Valid : out Boolean) is
      Item : Template_Access := new Template;
   begin
      Compile (Item.all, Source, Valid);
      if not Valid then
         Free (Item.all);
         Free (Item);
         return;
      end if;

      for Index in 1 .. This.Total loop
         if This.Items (Index).Name.all = String (Name) then
            Free (This.Items (Index).Item.all);
            Free (This.Items (Index).Item);
            This.Items (Index).Item := Item;
            return;
         end if;
      end loop;

      if This.Items = null or else This.Total = This.Items'Last then
         declare
            Larger : constant Named_Template_List_Access :=
              new Named_Template_List (1 .. (if This.Items = null then 16 else 2 * This.Items'Last));
         begin
            if This.Items /= null then
               Larger (1 .. This.Total) := This.Items (1 .. This.Total);
               Free (This.Items);
            end if;
            This.Items := Larger;
         end;
      end if;
      This.Total := This.Total + 1;
      This.Items (This.Total) := (Name => new String'(String (Name)), Item => Item);
   end Add;

   --  The whole of a file, or Read False.
   procedure Read_File (Path : String; Into : out String_Access; Read : out Boolean) is
      use Ada.Streams.Stream_IO;
      use type Ada.Directories.File_Size;
      File : File_Type;
      Size : Ada.Directories.File_Size;
   begin
      Into := null;
      Read := False;
      Size := Ada.Directories.Size (Path);
      if Size > Ada.Directories.File_Size (Buffers.Max_Capacity) then
         return;
      end if;
      Into := new String (1 .. Natural (Size));
      Open (File, In_File, Path);
      String'Read (Stream (File), Into.all);
      Close (File);
      Read := True;
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         Free (Into);
         Read := False;
   end Read_File;

   procedure Load_Directory
     (This      : in out Library;
      Directory : String;
      Loaded    : out Natural;
      Failed    : out Natural;
      Extension : String := ".mustache")
   is
      use Ada.Directories;
      Search : Search_Type;
      Found  : Directory_Entry_Type;
   begin
      Loaded := 0;
      Failed := 0;
      Start_Search (Search, Directory, "*" & Extension, [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Found);
         declare
            File_Name : constant String := Simple_Name (Found);
            Name      : constant String := File_Name (File_Name'First .. File_Name'Last - Extension'Length);
            Source    : String_Access;
            Read      : Boolean;
            Valid     : Boolean := False;
         begin
            Read_File (Full_Name (Found), Source, Read);
            if Read and then Encoding.Valid_Utf8 (Name) then
               Add (This, Encoding.To_UTF8 (Name), Source.all, Valid);
            end if;
            Free (Source);
            if Valid then
               Loaded := Loaded + 1;
            else
               Failed := Failed + 1;
            end if;
         end;
      end loop;
      End_Search (Search);
   exception
      when Name_Error | Use_Error =>
         Failed := Failed + 1;   --  no such directory
   end Load_Directory;

   function Contains (This : Library; Name : UTF8_String) return Boolean is (Find (This, String (Name)) /= null);

   procedure Render
     (This  : Library;
      Name  : String;
      Data  : Data_Source'Class;
      Into  : in out Buffer;
      Found : out Boolean)
   is
      Item  : constant Template_Access := Find (This, Name);
      Stack : Scope_Stack := [1 => Data.Top, others => 0];
   begin
      Found := Item /= null;
      if Found then
         Render_Template (Item.all, This'Unrestricted_Access, Data, Stack, 1, Into, 0);
      end if;
   end Render;

   procedure Free (This : in out Library) is begin
      for Index in 1 .. This.Total loop
         Free (This.Items (Index).Name);
         Free (This.Items (Index).Item.all);
         Free (This.Items (Index).Item);
      end loop;
      Free (This.Items);
      This.Total := 0;
   end Free;

end Sparrow.Templates;
