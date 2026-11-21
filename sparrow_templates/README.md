# sparrow_templates

Mustache templates (logic-less), compiled once at start-up and rendered straight into a `Buffer` (a
response's content).

```toml
[[depends-on]]
sparrow_templates = "~1.0.0"
```

| Syntax | Meaning |
|---|---|
| `{{name}}` | the value, HTML-escaped |
| `{{{name}}}`, `{{& name}}` | the value as it is |
| `{{#name}}…{{/name}}` | once per list item, once for an object or a true value |
| `{{^name}}…{{/name}}` | when the value is absent, false or an empty list |
| `{{> name}}` | another template of the library (a partial) |
| `{{a.b.c}}`, `{{.}}` | dotted names, the current item |
| `{{! comment}}` | nothing |

Not supported: lambdas, changing the delimiters, template inheritance.

## Use

```ada
Views : Templates.Library;
...
Templates.Load_Directory (Views, "templates", Loaded, Failed);     --  every *.mustache, by file name

declare
   Data : Bindings.Binding_Set;            --  frees itself
   Row  : Templates.Scope;
begin
   Bindings.Set (Data, "title", "Articles");
   for Each of Articles loop
      Row := Bindings.Add_Item (Data, "articles");
      Bindings.Set (Data, "title", Each.Title, Within => Row);
   end loop;
   Responses.Begin_Content (Response, OK, Text_Html);
   Templates.Render (Views, "articles", Data, Response.Content, Found);
end;
```

## Data sources

The engine asks a `Data_Source` for values by name. It has no data model of its own:

- `Sparrow.Templates.Bindings`: values set by hand, as above.
- `Sparrow.Templates.Json_Data`: a parsed `Sparrow.Json` document.
- Your own: implement the interface over records or database rows.

`Bindings.Add_Rows` puts database rows into a binding set as a list, every column a name, so a list page
sets no values by hand. It is generic over the rows, so this crate depends on no database:

```ada
procedure Add_Rows is new Sparrow.Templates.Bindings.Add_Rows (Sqlite.Statement);
...
Sqlite.Prepare (Db, Todos, "SELECT id, title, nullif(done, 0) AS done FROM todos");
Add_Rows (Data, "todos", Todos);         --  {{#todos}}{{title}}{{#done}} ✓{{/done}}{{/todos}}
```

Values become text; a NULL becomes false, hence `nullif` for flag columns. `Sparrow.Postgres.Queries`
has `Result_Reader` to instantiate it with.

Nothing else in Sparrow depends on this engine. Any engine that appends to a `Buffer` can replace it.

MIT licensed.
