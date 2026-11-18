with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Responses;
with Sparrow.Templates; use Sparrow.Templates;
with Sparrow.Templates.Bindings; use Sparrow.Templates.Bindings;

package body Article_Pages is

   Views : Library;

   procedure Load_Views is
      Loaded, Failed : Natural;
   begin
      --  Every *.mustache file, named by its file name.
      Load_Directory (Views, "templates", Loaded, Failed);
      if Failed > 0 then
         raise Program_Error with "a template does not parse";
      end if;
   end Load_Views;

   procedure Index
     (Request : Http_Request; Response : in out Http_Response)
   is
      pragma Unreferenced (Request);
      Data  : Binding_Set;   --  frees itself
      Found : Boolean;

      procedure Add_Article (Title : UTF8_String) is
         Row : constant Scope := Add_Item (Data, "articles");
      begin
         Set (Data, "title", Title, Within => Row);
      end Add_Article;
   begin
      Set (Data, "title", "Articles");
      Add_Article ("Hello, Ada");   --  in real life, a loop over your rows
      Add_Article ("Sparrow 0.1");
      Responses.Begin_Content (Response, OK, Text_Html);
      Render (Views, "articles", Data, Response.Content, Found);
   end Index;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Get, "/articles", Index'Access);
   end Register;

end Article_Pages;
