--  Mustache templates (logic-less): compiled once, rendered into a Buffer.
--
--     {{name}}        the value, HTML-escaped          {{{name}}} or {{&name}}   the value as it is
--     {{#name}}..{{/name}}   a section: once per item of a list, once for an object or a true value
--     {{^name}}..{{/name}}   an inverted section: when the value is absent, false or an empty list
--     {{! comment}}   {{> partial}}   {{a.b.c}} dotted names   {{.}} the current item
--
--  Not supported: lambdas, changing the delimiters, template inheritance.
--
--  The engine does not own a data model. It asks a Data_Source for values by name, so data can come from a
--  Sparrow.Json document (Sparrow.Templates.Json_Data), from values set by hand (Sparrow.Templates.Bindings),
--  or straight from an application's own records or database rows by implementing the interface.
--
--  Replacing this engine: nothing else in Sparrow depends on it. A handler's response body is a
--  Sparrow.Buffers.Buffer, and any engine that appends to one fits in the same place.
with Sparrow.Buffers; use Sparrow.Buffers;

package Sparrow.Templates is

   ---------------------------------------------------------------------------------------------------------------
   --  Where values come from.

   --  A place in the data where names are looked up: the top, an object, or one item of a list. What the
   --  numbers mean is the Data_Source's business.
   type Scope is new Natural;

   type Value_Kind is
     (Absent,        --  no such name here: the engine looks in the enclosing scopes
      False_Value,   --  false or null
      True_Value,
      Scalar,        --  text or a number: something Append_Value can write
      List,
      Object);

   type Data_Source is limited interface;

   --  The scope rendering starts in.
   function Top (This : Data_Source) return Scope is abstract;

   --  What Name is inside Within. Name is a single name, never dotted; "." is Within itself.
   function Kind_Of (This : Data_Source; Within : Scope; Name : UTF8_String) return Value_Kind is abstract;

   --  Append a Scalar's text to To, unescaped (the engine escapes it); nothing for other kinds.
   procedure Append_Value (This : Data_Source; Within : Scope; Name : UTF8_String; To : in out Buffer) is abstract;

   --  How many items a List has; 1 for an Object.
   function Item_Count (This : Data_Source; Within : Scope; Name : UTF8_String) return Natural is abstract;

   --  The scope of a List's Index-th item (from 1), or of an Object (Index = 1).
   function Item (This : Data_Source; Within : Scope; Name : UTF8_String; Index : Positive) return Scope is abstract;

   ---------------------------------------------------------------------------------------------------------------
   --  Templates.

   type Template is limited private;

   --  Compile Source (bytes, as read from a file). Valid is False when it is not UTF-8, for an unclosed tag,
   --  and for a section closed under another name or never closed.
   procedure Compile (This : in out Template; Source : String; Valid : out Boolean);

   --  Where the first error is in the source last compiled (a character position; 0 when it compiled).
   function Error_Position (This : Template) return Natural;

   --  Append the rendering to Into. Partials render as nothing (there is no Library to find them in); a
   --  template that did not compile renders as nothing.
   procedure Render (This : Template; Data : Data_Source'Class; Into : in out Buffer);

   procedure Free (This : in out Template);

   ---------------------------------------------------------------------------------------------------------------
   --  Named templates, which can include each other as partials. Build a Library at start-up, then only
   --  render from it: tasks share it without locking.

   type Library is limited private;

   --  Compile Source under Name, replacing a template already there.
   procedure Add (This : in out Library; Name : UTF8_String; Source : String; Valid : out Boolean);

   --  Add every file of Directory ending in Extension, named by its file name without the extension
   --  ("layout.mustache" is "layout"). Loaded counts those that compiled, Failed those that did not or could
   --  not be read.
   procedure Load_Directory
     (This      : in out Library;
      Directory : String;
      Loaded    : out Natural;
      Failed    : out Natural;
      Extension : String := ".mustache");

   function Contains (This : Library; Name : UTF8_String) return Boolean;

   --  Render the template Name; Found is False (and nothing is appended) when there is none. A partial that
   --  is missing renders as nothing; partials nested deeper than Max_Partial_Depth stop there.
   procedure Render
     (This  : Library;
      Name  : String;
      Data  : Data_Source'Class;
      Into  : in out Buffer;
      Found : out Boolean);

   Max_Partial_Depth : constant := 32;

   procedure Free (This : in out Library);

   ---------------------------------------------------------------------------------------------------------------
   --  For HTML written by hand: Text with & < > " ' escaped.

   procedure Append_Html_Escaped (To : in out Buffer; Text : UTF8_String);

private

   type Operation_Kind is
     (Literal,            --  source text as it is
      Variable,           --  {{name}}
      Raw_Variable,       --  {{{name}}}
      Section_Open,       --  {{#name}}
      Inverted_Open,      --  {{^name}}
      Section_Close,      --  {{/name}}
      Partial);           --  {{> name}}

   type Operation is record
      Kind    : Operation_Kind := Literal;
      First   : Positive := 1;   --  Source (First .. Last): the literal's text, or the tag's name
      Last    : Natural := 0;
      Partner : Natural := 0;    --  a section's opening and closing operations name each other
   end record;

   type Operation_List is array (Positive range <>) of Operation;
   type Operation_List_Access is access Operation_List;

   type Template is limited record
      Source          : String_Access;
      Operations      : Operation_List_Access;
      Operation_Total : Natural := 0;
      Error_At        : Natural := 0;
   end record;

   type Template_Access is access Template;

   type Named_Template is record
      Name : String_Access;
      Item : Template_Access;
   end record;

   type Named_Template_List is array (Positive range <>) of Named_Template;
   type Named_Template_List_Access is access Named_Template_List;

   type Library is limited record
      Items : Named_Template_List_Access;
      Total : Natural := 0;
   end record;

end Sparrow.Templates;
