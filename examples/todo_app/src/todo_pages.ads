--  The pages and fragments of the todo app. GET / renders the whole page; every change answers with the
--  list again (htmx swaps it in) plus the footer out of band, so the counts and filters stay right.
--
--     GET    /                      the page; ?filter=all|active|done
--     GET    /todos                 the list and footer only (the filter links)
--     POST   /todos                 add one: form field title
--     PATCH  /todos/:id/toggle      done or not done
--     DELETE /todos/:id
--     POST   /todos/clear           delete every finished todo
--     GET    /static/*file          the stylesheet, icon and htmx
--
--  Changes need the header htmx sends with every request here (X-Requested-With: htmx). A page on another site
--  cannot add it to a cross-site request without CORS allowing it, so that header is the CSRF defense.
with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Todo_Pages is

   --  Compile every template of Directory; Program_Error when one does not compile.
   procedure Load_Views (Directory : String);

   procedure Open_Connection (Worker : Worker_Id);
   procedure Close_Connection (Worker : Worker_Id);

   procedure Home (Request : Http_Request; Response : in out Http_Response);
   procedure List (Request : Http_Request; Response : in out Http_Response);
   procedure Add (Request : Http_Request; Response : in out Http_Response);
   procedure Toggle (Request : Http_Request; Response : in out Http_Response);
   procedure Remove (Request : Http_Request; Response : in out Http_Response);
   procedure Clear_Done (Request : Http_Request; Response : in out Http_Response);


end Todo_Pages;
