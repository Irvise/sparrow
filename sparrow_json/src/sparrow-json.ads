--  A small JSON reader. A document is a flat table of nodes linked to their first child and next sibling,
--  with storage bounded by its discriminants: parsing never allocates, and a document is reused from one
--  request to the next. Strings are decoded (escapes resolved) into the document's own text area.
--
--  SPARK: no input makes the parser or the accessors raise, read outside the source or the document, or loop
--  forever. Input that is not valid JSON, is not valid UTF-8, nests past Max_Depth or does not fit the
--  document is refused. The source is bytes; what comes out of a parsed document is text (UTF8_String),
--  because the parser checked it.
--
--  Writing JSON is Sparrow.Json.Writers.
package Sparrow.Json with SPARK_Mode is

   type Kind is (Null_Kind, True_Kind, False_Kind, Number_Kind, String_Kind, Array_Kind, Object_Kind);

   type Node_Count is range 0 .. 2 ** 20;
   subtype Node_Index is Node_Count range 1 .. Node_Count'Last;
   No_Node : constant Node_Count := 0;
   Root    : constant Node_Index := 1;

   Max_Depth : constant := 64;

   type Document (Node_Capacity : Node_Index; Text_Capacity : Positive) is limited private;

   type Parse_Options is record
      Allow_Nul : Boolean := False;   --  accept \u0000 inside strings (Postgres text cannot hold it)
   end record;

   Default_Options : constant Parse_Options := (others => <>);

   --  Parse Source into This; on success the top-level value is node Root.
   procedure Parse
     (This    : in out Document;
      Source  : String;
      Valid   : out Boolean;
      Options : Parse_Options := Default_Options)
      with Pre => Source'First >= 1
                  and then Source'Last < Positive'Last
                  and then This.Text_Capacity < Positive'Last,
           Post => Is_Valid (This) = Valid;

   --  Whether the last Parse of This succeeded; False for a document never parsed.
   function Is_Valid (This : Document) return Boolean;

   ---------------------------------------------------------------------------------------------------------------
   --  Reading. Every accessor is total: an absent node reads as JSON null, "", 0 or False.

   function Kind_Of (This : Document; Item : Node_Count) return Kind;

   --  The member Name of an object node; No_Node when absent or when Object is not an object.
   function Member (This : Document; Object : Node_Count; Name : UTF8_String) return Node_Count;

   --  The children of an array or object, in source order.
   function First_Child (This : Document; Item : Node_Count) return Node_Count
      with Post => First_Child'Result = No_Node or else First_Child'Result > Item;
   function Next_Sibling (This : Document; Item : Node_Count) return Node_Count
      with Post => Next_Sibling'Result = No_Node or else Next_Sibling'Result > Item;
   function Child_Count (This : Document; Item : Node_Count) return Natural;

   --  The member name of a child of an object; "" for other nodes.
   function Name (This : Document; Item : Node_Count) return UTF8_String;

   --  A string's decoded text or a number's text as written; "" for other kinds.
   function Value (This : Document; Item : Node_Count) return UTF8_String;

   function Boolean_Value (This : Document; Item : Node_Count) return Boolean;   --  True only for true

   --  A number with no fraction or exponent that fits; Valid is False (and Value 0) otherwise.
   procedure Get_Integer (This : Document; Item : Node_Count; Value : out Long_Long_Integer; Valid : out Boolean)
      with Post => (if not Valid then Value = 0);

   procedure Get_Float (This : Document; Item : Node_Count; Value : out Long_Float; Valid : out Boolean)
      with Post => (if not Valid then Value = 0.0);

   ---------------------------------------------------------------------------------------------------------------
   --  Paths. A path names a node below From: member names separated by '.', where a decimal step picks an
   --  array element by position from 0 ("items.0.title"). "" is From itself. A member whose name holds a '.'
   --  is reached with Member instead.
   --
   --     Title : constant UTF8_String := Json.Text (Doc, "title");
   --     Count : constant Long_Long_Integer := Json.Integer_Value (Doc, "page.count", Default => 1);

   --  The node at Path; No_Node when a step is missing.
   function Find (This : Document; Path : UTF8_String; From : Node_Count := Root) return Node_Count;

   function Has (This : Document; Path : UTF8_String; From : Node_Count := Root) return Boolean is
     (Find (This, Path, From) /= No_Node);

   --  The element at Position (from 0) of an array node; No_Node past its end or for other nodes.
   function Element (This : Document; List : Node_Count; Position : Natural) return Node_Count
      with Post => Element'Result = No_Node or else Element'Result > List;

   --  The value at Path, or Default when it is missing or of another kind. Text is for strings only;
   --  Integer_Value for numbers without fraction or exponent that fit; Float_Value for any number.
   function Text
     (This : Document; Path : UTF8_String; Default : UTF8_String := ""; From : Node_Count := Root)
      return UTF8_String;
   function Integer_Value
     (This : Document; Path : UTF8_String; Default : Long_Long_Integer := 0; From : Node_Count := Root)
      return Long_Long_Integer;
   function Float_Value
     (This : Document; Path : UTF8_String; Default : Long_Float := 0.0; From : Node_Count := Root)
      return Long_Float;
   function Boolean_Value
     (This : Document; Path : UTF8_String; Default : Boolean := False; From : Node_Count := Root) return Boolean;

   --  The number of elements or members of the array or object at Path; 0 for anything else.
   function Length (This : Document; Path : UTF8_String := ""; From : Node_Count := Root) return Natural;

   ---------------------------------------------------------------------------------------------------------------
   --  Checking a request body in one call:
   --
   --     Problem : constant UTF8_String :=
   --       Json.Problem (Doc, [Json.Required ("title", Json.Text_Shape, Shortest => 1, Longest => 200),
   --                           Json.Optional ("tags", Json.Array_Shape, Longest => 10)]);
   --     if Problem /= "" then
   --        Responses.Send (Response, Unprocessable_Content, Problem);   --  "title: required"
   --        return;
   --     end if;

   type Shape is (Text_Shape, Number_Shape, Integer_Shape, Boolean_Shape, Array_Shape, Object_Shape, Any_Shape);

   Max_Rule_Path : constant := 64;

   type Rule is private;
   type Rule_List is array (Positive range <>) of Rule;

   --  The value at Path must be there and have Of_Shape. For text, Shortest .. Longest bounds its length in
   --  bytes; for arrays and objects, their number of elements or members. For integers, Least .. Most bounds
   --  the value. Bounds that do not apply to the shape are not used.
   function Required
     (Path     : UTF8_String;
      Of_Shape : Shape;
      Shortest : Natural := 0;
      Longest  : Natural := Natural'Last;
      Least    : Long_Long_Integer := Long_Long_Integer'First;
      Most     : Long_Long_Integer := Long_Long_Integer'Last) return Rule
      with Pre => Path'Length <= Max_Rule_Path;

   --  The same, when the value is there.
   function Optional
     (Path     : UTF8_String;
      Of_Shape : Shape;
      Shortest : Natural := 0;
      Longest  : Natural := Natural'Last;
      Least    : Long_Long_Integer := Long_Long_Integer'First;
      Most     : Long_Long_Integer := Long_Long_Integer'Last) return Rule
      with Pre => Path'Length <= Max_Rule_Path;

   --  "" when From is an object and every rule holds; otherwise the first problem, worded for the client:
   --  "title: required", "count: must be an integer", "title: must have 1 to 200 bytes",
   --  "count: must be from 1 to 100".
   function Problem (This : Document; Rules : Rule_List; From : Node_Count := Root) return UTF8_String;

private

   type Rule is record
      Path        : String (1 .. Max_Rule_Path) := [others => ' '];
      Path_Length : Natural range 0 .. Max_Rule_Path := 0;
      Needed      : Boolean := True;
      Of_Shape    : Shape := Any_Shape;
      Shortest    : Natural := 0;
      Longest     : Natural := Natural'Last;
      Least       : Long_Long_Integer := Long_Long_Integer'First;
      Most        : Long_Long_Integer := Long_Long_Integer'Last;
   end record;

   --  A range of the document's text; First > Last when empty.
   type Span is record
      First : Positive := 1;
      Last  : Natural := 0;
   end record;

   type Node is record
      Of_Kind      : Kind := Null_Kind;
      Key          : Span;   --  member name, for the children of an object
      Value        : Span;   --  decoded string, or the number's text
      First_Child  : Node_Count := No_Node;
      Next_Sibling : Node_Count := No_Node;
   end record;

   type Node_Array is array (Node_Index range <>) of Node;

   type Document (Node_Capacity : Node_Index; Text_Capacity : Positive) is limited record
      Nodes       : Node_Array (1 .. Node_Capacity);
      Node_Total  : Node_Count := 0;
      Text        : String (1 .. Text_Capacity) := [others => ' '];
      Text_Length : Natural := 0;
      Parsed      : Boolean := False;   --  the last Parse succeeded
   end record;

   function Is_Valid (This : Document) return Boolean is (This.Parsed);

end Sparrow.Json;
