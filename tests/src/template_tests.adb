with Checks; use Checks;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Json;
with Sparrow.Templates; use Sparrow.Templates;
with Sparrow.Templates.Bindings; use Sparrow.Templates.Bindings;
with Sparrow.Templates.Json_Data; use Sparrow.Templates.Json_Data;

procedure Template_Tests is
   use Sparrow;

   Data : Binding_Set;

   --  Source rendered against Data, or "<invalid>" when it does not compile.
   function Rendered (Source : String; From : Data_Source'Class := Data) return String is
      Page  : Template;
      Into  : Buffer;
      Valid : Boolean;
   begin
      Compile (Page, Source, Valid);
      if not Valid then
         Free (Page);
         return "<invalid>";
      end if;
      Render (Page, From, Into);
      return Result : constant String := Content (Into) do
         Free (Into);
         Free (Page);
      end return;
   end Rendered;

   Author : Scope;
   LF          : constant Character := ASCII.LF;
begin
   Set (Data, "name", "Ada");
   Set (Data, "html", "<b>&""'</b>");
   Set (Data, "count", Long_Long_Integer'(42));
   Set (Data, "yes", True);
   Set (Data, "no", False);
   Set_Empty_List (Data, "nothing");
   Set (Data, "item", "one", Within => Add_Item (Data, "list"));
   Set (Data, "item", "two", Within => Add_Item (Data, "list"));
   Set (Data, "item", "three", Within => Add_Item (Data, "list"));
   Author := Add_Object (Data, "author");
   Set (Data, "name", "Lovelace", Within => Author);

   Equal (Rendered ("Hello, {{name}}!"), "Hello, Ada!", "variable");
   Equal (Rendered ("{{ name }}"), "Ada", "blanks inside a tag");
   Equal (Rendered ("{{html}}"), "&lt;b&gt;&amp;&quot;&#39;&lt;/b&gt;", "escaped");
   Equal (Rendered ("{{{html}}}|{{&html}}"), "<b>&""'</b>|<b>&""'</b>", "unescaped");
   Equal (Rendered ("{{count}} {{missing}}."), "42 .", "number; absent is empty");
   Equal (Rendered ("{{#list}}[{{item}}]{{/list}}"), "[one][two][three]", "a list section");
   Equal (Rendered ("{{#list}}{{name}}{{/list}}"), "AdaAdaAda", "names fall through to outer scopes");
   Equal (Rendered ("{{#yes}}y{{/yes}}{{#no}}n{{/no}}{{^no}}!n{{/no}}"), "y!n", "flags");
   Equal (Rendered ("{{#nothing}}x{{/nothing}}{{^nothing}}empty{{/nothing}}"), "empty", "an empty list");
   Equal (Rendered ("{{^missing}}absent{{/missing}}"), "absent", "an inverted section on an absent name");
   Equal (Rendered ("{{#author}}{{name}}{{/author}} {{author.name}}"), "Lovelace Lovelace",
          "object section and dotted name");
   Equal (Rendered ("{{author.missing.deeper}}|{{name.x}}"), "|", "a dotted name through nothing");
   Equal (Rendered ("a{{! a comment }}b"), "ab", "comment");
   Equal (Rendered ("<ul>" & LF & "{{#list}}" & LF & "  <li>{{item}}</li>" & LF & "{{/list}}" & LF & "</ul>"),
          "<ul>" & LF & "  <li>one</li>" & LF & "  <li>two</li>" & LF & "  <li>three</li>" & LF & "</ul>",
          "standalone section lines leave no blank lines");
   Equal (Rendered ("  {{#yes}}  " & ASCII.CR & LF & "x" & LF & "{{/yes}}"), "x" & LF, "standalone with CRLF");
   Equal (Rendered ("a {{#yes}}b{{/yes}} c"), "a b c", "inline sections keep their blanks");
   Equal (Rendered ("{{> nowhere}}x"), "x", "a partial without a library renders nothing");

   Equal (Rendered ("{{#list}}"), "<invalid>", "an unclosed section");
   Equal (Rendered ("{{#a}}{{/b}}"), "<invalid>", "a section closed under another name");
   Equal (Rendered ("{{/a}}"), "<invalid>", "closing what was never opened");
   Equal (Rendered ("{{name"), "<invalid>", "an unclosed tag");
   Equal (Rendered ("{{=<% %>=}}"), "<invalid>", "changing delimiters is not supported");
   Equal (Rendered ("{{}}"), "<invalid>", "an empty tag");
   Equal (Rendered ("a" & Character'Val (255)), "<invalid>", "source that is not UTF-8");
   declare
      Page  : Template;
      Valid : Boolean;
   begin
      Compile (Page, "ok {{#x}} no close", Valid);
      Check (not Valid and then Error_Position (Page) = 4, "error position");
      Free (Page);
   end;

   --  The same template over JSON.
   declare
      Document : aliased Json.Document (Node_Capacity => 256, Text_Capacity => 4096);
      Valid    : Boolean;
   begin
      Json.Parse (Document,
        ("{""name"":""Ada"",""list"":[{""item"":""one""},{""item"":2}],""tags"":[""a"",""<b>""],"
         & """author"":{""name"":""Lovelace""},""yes"":true,""no"":null,""none"":[]}"), Valid);
      Check (Valid, "parse the JSON data");
      declare
         Source : Json_Source (Document'Access);
      begin
         Equal (Rendered ("{{name}}:{{#list}}[{{item}}]{{/list}}", Source), "Ada:[one][2]", "JSON list");
         Equal (Rendered ("{{#tags}}({{.}}){{/tags}}", Source), "(a)(&lt;b&gt;)", "JSON scalars as {{.}}");
         Equal (Rendered ("{{author.name}}{{#yes}}!{{/yes}}{{^no}}?{{/no}}{{^none}}0{{/none}}", Source),
                "Lovelace!?0", "JSON objects, true, null, empty arrays");
      end;
   end;

   --  A library loaded from files, with partials.
   declare
      Pages          : Library;
      Loaded, Failed : Natural;
      Into           : Buffer;
      Found          : Boolean;
      Items          : Binding_Set;
   begin
      Load_Directory (Pages, "templates", Loaded, Failed);
      Check (Loaded = 2 and then Failed = 1, "load a directory");
      Check (Contains (Pages, "page") and then not Contains (Pages, "broken"), "named by file");
      Set (Items, "title", "T");
      Set (Items, "name", "x", Within => Add_Item (Items, "items"));
      Set (Items, "name", "y", Within => Add_Item (Items, "items"));
      Render (Pages, "page", Items, Into, Found);
      Check (Found, "render by name");
      Equal (Content (Into), "<h1>T</h1>" & LF & "<li>x</li>" & LF & "<li>y</li>" & LF, "partials");
      Clear (Into);
      Render (Pages, "absent", Items, Into, Found);
      Check (not Found and then Into.Length = 0, "an absent template");

      declare
         Valid : Boolean;
      begin
         Add (Pages, "loop", "{{> loop}}x", Valid);
         Render (Pages, "loop", Items, Into, Found);
         Check (Valid and then Found and then Into.Length = Max_Partial_Depth + 1,
                "a partial that includes itself stops at the depth limit");
      end;
      Free (Into);
      Free (Items);
      Free (Pages);
   end;

   Free (Data);
   Finish ("templates");
end Template_Tests;
