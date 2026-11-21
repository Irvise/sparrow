# sparrow_json

A JSON reader that never allocates and a writer that streams into a buffer. Both are proved free of
run-time errors (SPARK silver): no input makes them raise, read out of bounds or loop forever.

```toml
[[depends-on]]
sparrow_json = "~1.0.0"
```

## Reading

A `Document` is a flat table of nodes. Its size is fixed by its discriminants, so it can be reused from one
request to the next.

```ada
Doc   : Json.Document (Node_Capacity => 256, Text_Capacity => 8192);
Valid : Boolean;
...
Json.Parse (Doc, Requests.Content (Request), Valid);
if Valid then
   Save (Json.Text (Doc, "title"),                        --  UTF8_String: the parser checked it
         Json.Integer_Value (Doc, "page.count", Default => 1),
         Json.Boolean_Value (Doc, "items.0.done"));        --  a number picks an array element, from 0
end if;
```

- Input that is not valid JSON or valid UTF-8, nests past `Max_Depth` or does not fit is refused
  (`Valid = False`).
- Paths are member names separated by `.`; a decimal step picks an array element. `Find` gives the node,
  `Has` whether it is there, `Length` the size of an array or object. A member whose name holds a `.` is
  reached with `Member`.
- Every accessor is total. A missing value, or one of another kind, reads as the `Default` (`""`, `0`,
  `False` unless given).
- `Is_Valid (Doc)` says whether the last `Parse` succeeded.
- Underneath, `Member`, `Element`, `First_Child` and `Next_Sibling` walk the node table; `Get_Integer` and
  `Get_Float` report whether a number fits.
- In a server, `Sparrow.Http.Requests.Json_Body (Request)` parses the body into a document sized to it.

`Sparrow.Json.Iteration` loops over an array's elements or an object's members; the loop variable is the
child's node:

```ada
for Item in Json.Iteration.Elements (Doc, "items") loop
   Show (Json.Text (Doc, "title", From => Item));
end loop;
```

## Checking a request body

`Problem` checks a document against a list of rules in one call and returns `""` or the first problem,
worded for the client:

```ada
Problem : constant UTF8_String :=
  Json.Problem (Doc, [Json.Required ("title", Json.Text_Shape, Shortest => 1, Longest => 200),
                      Json.Optional ("tags", Json.Array_Shape, Longest => 10),
                      Json.Required ("count", Json.Integer_Shape)]);
if Problem /= "" then
   Responses.Send (Response, Unprocessable_Content, Problem);    --  "title: required"
   return;
end if;
```

Shapes: text, number, integer, boolean, array, object, any. `Shortest`/`Longest` bound a text's length in
bytes, or an array's or object's size; `Least`/`Most` bound an integer. A `null` counts as missing.

Once `Problem` returns `""`, read the values with the path accessors: `Text (Doc, "title")`. Declare a
rule list once, as a constant, when several handlers take the same body.

## Writing

A `Builders.Builder` writes into the buffer it is bound to:

```ada
Json : Builders.Builder (Response.Content'Access);
...
Json.Begin_Object;
   Json.Member ("id", 42);
   Json.Key ("tags");
   Json.Begin_Array;
      Json.Value ("ada");
   Json.End_Array;
Json.End_Object;                         --  {"id":42,"tags":["ada"]}
```

Strings are escaped. A call that does not fit the structure (a `Key` outside an object, an unmatched `End`)
writes nothing and clears `Well_Formed`. Check `Complete` before sending.

The builder wraps `Writers.Writer`, which takes the buffer on every call (`Member (W, Into, "id", 42)`) and
is the form to use in SPARK code: it is proved, the builder is not.

MIT licensed.
