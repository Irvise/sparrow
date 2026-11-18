with Ada.Strings.Unbounded;
with Checks; use Checks;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Builders;
with Sparrow.Json.Iteration;
with Sparrow.Json.Writers; use Sparrow.Json.Writers;

procedure Json_Tests is
   use Sparrow;
   Doc   : Document (Node_Capacity => 64, Text_Capacity => 1024);
   Small : Document (Node_Capacity => 2, Text_Capacity => 4);
   Valid : Boolean;

   procedure Accepts (Source : String; Name : String) is begin
      Parse (Doc, Source, Valid);
      Check (Valid, "accepts " & Name);
   end Accepts;

   procedure Refuses (Source : String; Name : String) is begin
      Parse (Doc, Source, Valid);
      Check (not Valid, "refuses " & Name);
   end Refuses;
begin
   Parse (Doc, "{""name"": ""Ada é𝄞\n"", ""n"": [1, -2.5e3, true, null], ""o"": {}}", Valid);
   Check (Valid, "parse object");
   Check (Kind_Of (Doc, Root) = Object_Kind, "root kind");
   Equal (String (Value (Doc, Member (Doc, Root, "name"))), "Ada é𝄞" & ASCII.LF, "string with escapes");
   declare
      List  : constant Node_Count := Member (Doc, Root, "n");
      Item  : Node_Count := First_Child (Doc, List);
      Whole : Long_Long_Integer;
      Real  : Long_Float;
   begin
      Check (Kind_Of (Doc, List) = Array_Kind and then Child_Count (Doc, List) = 4, "array");
      Get_Integer (Doc, Item, Whole, Valid);
      Check (Valid and then Whole = 1, "integer");
      Item := Next_Sibling (Doc, Item);
      Get_Integer (Doc, Item, Whole, Valid);
      Check (not Valid, "a fraction is not an integer");
      Get_Float (Doc, Item, Real, Valid);
      Check (Valid and then Real = -2500.0, "float");
      Item := Next_Sibling (Doc, Item);
      Check (Boolean_Value (Doc, Item), "true");
      Item := Next_Sibling (Doc, Item);
      Check (Kind_Of (Doc, Item) = Null_Kind and then Next_Sibling (Doc, Item) = No_Node, "null, then the end");
   end;
   Equal (String (Name (Doc, Member (Doc, Root, "o"))), "o", "member name");
   Check (Member (Doc, Root, "missing") = No_Node and then Value (Doc, No_Node) = "", "absent reads as nothing");

   Accepts ("0", "zero");
   Accepts (" [ ] ", "blanks");
   Accepts ("-0.5E+10", "exponent");
   Refuses ("", "empty");
   Refuses ("01", "leading zero");
   Refuses ("1.", "bare point");
   Refuses (".5", "no integer part");
   Refuses ("1.2.3", "two points");
   Refuses ("1e", "bare exponent");
   Refuses ("-", "bare minus");
   Refuses ("[1,]", "trailing comma");
   Refuses ("{""a"":1,}", "trailing comma in object");
   Refuses ("{a:1}", "bare key");
   Refuses ("[1] 2", "trailing value");
   Refuses ("""abc", "unclosed string");
   Refuses ("""" & ASCII.HT & """", "raw control character");
   Refuses ("""\ud834""", "lone surrogate");
   Refuses ("""\u0000""", "NUL by default");
   Refuses ("""" & Character'Val (16#FF#) & """", "invalid UTF-8");
   Refuses ("nul", "cut literal");
   Refuses ([1 .. 70 => '['] & [1 .. 70 => ']'], "too deep");
   Parse (Doc, """\u0000""", Valid, (Allow_Nul => True));
   Check (Valid and then Value (Doc, Root) = [1 => ASCII.NUL], "NUL when allowed");
   Parse (Small, "[1,2,3]", Valid);
   Check (not Valid, "too many nodes for the document");
   Parse (Small, """abcdef""", Valid);
   Check (not Valid, "too much text for the document");

   --  writer
   declare
      Page : Buffer;
      W    : Writer;
   begin
      Begin_Object (W, Page);
      Member (W, Page, "id", 42);
      Key (W, Page, "tags");
      Begin_Array (W, Page);
      Value (W, Page, "ada");
      Value (W, Page, "q""\" & ASCII.LF & ASCII.SOH);
      End_Array (W, Page);
      Member (W, Page, "ok", True);
      Key (W, Page, "x");
      Null_Value (W, Page);
      Key (W, Page, "f");
      Begin_Array (W, Page);
      Value (W, Page, Long_Float'(0.1));
      Value (W, Page, Long_Float'(-2.0));
      Value (W, Page, Long_Float'(1.5E300));
      Value (W, Page, Long_Float'(1.0E-7));
      Value (W, Page, Long_Float'(123456.789));
      End_Array (W, Page);
      Key (W, Page, "raw");
      Raw_Value (W, Page, "{}");
      End_Object (W, Page);
      Equal (Content (Page),
             "{""id"":42,""tags"":[""ada"",""q\""\\\n\u0001""],""ok"":true,""x"":null,"
             & """f"":[0.1,-2,1.5e300,1e-7,123456.789],""raw"":{}}", "writer output");
      Check (Well_Formed (W) and then Complete (W), "writer well formed");
      Parse (Doc, Content (Page), Valid);
      Check (Valid, "writer output parses");

      Value (W, Page, "extra");
      Check (not Well_Formed (W), "a second top-level value is refused");
      Free (Page);
   end;
   declare
      Page : Buffer;
      W    : Writer;
   begin
      Begin_Object (W, Page);
      Value (W, Page, "no key");
      Check (not Well_Formed (W), "a value without a key is refused");
      Free (Page);
   end;
   declare
      Page : Buffer;
      W    : Writer;
   begin
      Begin_Array (W, Page);
      End_Object (W, Page);
      Check (not Well_Formed (W), "a mismatched end is refused");
      Free (Page);
   end;

   --  paths and rules
   Parse (Doc, "{""title"": ""Ada"", ""page"": {""count"": 3, ""ratio"": 0.5, ""last"": true},"
               & " ""items"": [{""id"": 7}, {""id"": 8}], ""a.b"": 1, ""none"": null}", Valid);
   Check (Valid, "parse for paths");
   Equal (String (Text (Doc, "title")), "Ada", "text by path");
   Equal (String (Text (Doc, "page.count", Default => "?")), "?", "text of a number: the default");
   Check (Integer_Value (Doc, "page.count") = 3 and then Integer_Value (Doc, "page.ratio", Default => -1) = -1,
          "integer by path");
   Check (Float_Value (Doc, "page.ratio") = 0.5 and then Float_Value (Doc, "page.count") = 3.0, "float by path");
   Check (Boolean_Value (Doc, "page.last") and then Boolean_Value (Doc, "title", Default => True), "boolean by path");
   Check (Integer_Value (Doc, "items.1.id") = 8 and then not Has (Doc, "items.2.id") and then not Has (Doc, "items.x"),
          "array positions in paths");
   Check (Length (Doc, "items") = 2 and then Length (Doc) = 5 and then Length (Doc, "title") = 0, "length by path");
   Check (not Has (Doc, "a.b") and then Member (Doc, Root, "a.b") /= No_Node, "a dotted name needs Member");
   Check (not Has (Doc, "page.") and then not Has (Doc, ".page") and then not Has (Doc, "page..count"),
          "empty path steps find nothing");
   Check (Find (Doc, "") = Root and then Find (Doc, "count", From => Find (Doc, "page")) = Find (Doc, "page.count"),
          "paths from a node");
   Check (Integer_Value (Doc, "id", From => Element (Doc, Find (Doc, "items"), 0)) = 7, "element by position");

   Equal (String (Problem (Doc, [Required ("title", Text_Shape, Shortest => 1, Longest => 200),
                                 Required ("page.count", Integer_Shape),
                                 Optional ("missing", Array_Shape),
                                 Optional ("none", Text_Shape)])), "", "rules that hold");
   Equal (String (Problem (Doc, [Required ("note", Text_Shape)])), "note: required", "a missing value");
   Equal (String (Problem (Doc, [Required ("none", Text_Shape)])), "none: required", "null counts as missing");
   Equal (String (Problem (Doc, [Required ("page.ratio", Integer_Shape)])), "page.ratio: must be an integer",
          "a value of the wrong shape");
   Equal (String (Problem (Doc, [Required ("title", Text_Shape, Shortest => 5, Longest => 10)])),
          "title: must have 5 to 10 bytes", "text too short");
   Equal (String (Problem (Doc, [Optional ("items", Array_Shape, Longest => 1)])),
          "items: must have at most 1 element", "too many elements");
   Parse (Doc, "[1]", Valid);
   Equal (String (Problem (Doc, [Optional ("x", Any_Shape)])), "the body must be a JSON object", "not an object");

   --  validity, iteration, integer bounds
   Parse (Doc, "{""items"": [{""n"": 1}, {""n"": 2}, {""n"": 3}], ""labels"": {""a"": ""x"", ""b"": ""y""},"
               & " ""count"": 7}", Valid);
   Check (Valid and then Is_Valid (Doc), "a parsed document is valid");
   declare
      Total : Long_Long_Integer := 0;
      Names : Ada.Strings.Unbounded.Unbounded_String;
      Seen  : Natural := 0;
   begin
      for Item in Iteration.Elements (Doc, "items") loop
         Total := Total + Integer_Value (Doc, "n", From => Item);
      end loop;
      for Field in Iteration.Members (Doc, "labels") loop
         Ada.Strings.Unbounded.Append (Names, String (Name (Doc, Field)) & "=" & String (Value (Doc, Field)) & ";");
      end loop;
      for Item in Iteration.Elements (Doc, "labels") loop   --  not an array: nothing
         Seen := Seen + 1;
      end loop;
      for Item in Iteration.Elements (Doc, "missing") loop
         Seen := Seen + 1;
      end loop;
      Check (Total = 6, "elements of an array");
      Equal (Ada.Strings.Unbounded.To_String (Names), "a=x;b=y;", "members of an object");
      Check (Seen = 0, "no elements in an object or a missing value");
   end;
   Equal (String (Problem (Doc, [Required ("count", Integer_Shape, Least => 1, Most => 5)])),
          "count: must be from 1 to 5", "an integer out of range");
   Equal (String (Problem (Doc, [Required ("count", Integer_Shape, Most => 5)])), "count: must be at most 5",
          "an integer above its most");
   Equal (String (Problem (Doc, [Required ("count", Integer_Shape, Least => 8)])), "count: must be at least 8",
          "an integer below its least");
   Equal (String (Problem (Doc, [Required ("count", Integer_Shape, Least => 7, Most => 7)])), "",
          "an integer in range");
   Parse (Doc, "{""broken"": ", Valid);
   Check (not Valid and then not Is_Valid (Doc), "a failed parse leaves the document invalid");

   --  the bound writer
   declare
      Into : aliased Buffer;
      Json : Builders.Builder (Into'Access);
   begin
      Json.Begin_Object;
      Json.Member ("id", 42);
      Json.Member ("ratio", 0.5);
      Json.Member ("ok", True);
      Json.Null_Member ("none");
      Json.Key ("tags");
      Json.Begin_Array;
      Json.Value ("a");
      Json.Value (Long_Long_Integer'(2));
      Json.End_Array;
      Json.End_Object;
      Check (Json.Complete and then Json.Well_Formed, "a builder writes a whole value");
      Equal (Content (Into), "{""id"":42,""ratio"":0.5,""ok"":true,""none"":null,""tags"":[""a"",2]}",
             "a builder's output");
      Json.End_Object;
      Check (not Json.Well_Formed, "a builder misused is no longer well formed");
      Free (Into);
   end;

   Finish ("json");
end Json_Tests;
