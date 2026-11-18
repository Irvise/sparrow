--  Database rows as a template list: every row an item, every column a name in it. A list page then sets no
--  values by hand:
--
--     procedure Add_Rows is new Sparrow.Templates.Bindings.Add_Rows (Sqlite.Statement);   --  library level
--     ...
--     Prepare (Db, Todos, "SELECT id, title, nullif(done, 0) AS done FROM todos ORDER BY id");
--     Add_Rows (Data, "todos", Todos);   --  {{#todos}}<li>{{title}}{{#done}} ✓{{/done}}</li>{{/todos}}
--
--  The formals match Sparrow.Sqlite.Statement as they are, and Sparrow.Postgres.Queries.Result_Reader; any
--  other source of rows works the same way. Values become text; a NULL becomes false, so a flag column reads
--  as a section when written nullif(flag, 0) (SQLite) or nullif(flag, false) (Postgres). Rows are copied, so
--  the statement can be reset or finalized before rendering. Name is bound to an empty list when there are
--  no rows.
generic
   type Rows (<>) is limited private;
   with function Next_Row (From : in out Rows) return Boolean is <>;
   with function Column_Count (From : Rows) return Natural is <>;
   with function Column_Name (From : Rows; Column : Positive) return String is <>;
   with function Is_Null (From : Rows; Column : Positive) return Boolean is <>;
   with function Text (From : Rows; Column : Positive) return UTF8_String is <>;
procedure Sparrow.Templates.Bindings.Add_Rows
  (This : in out Binding_Set; Name : UTF8_String; From : in out Rows; Within : Scope := Top_Scope);
