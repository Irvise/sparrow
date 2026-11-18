--  The pages of the forum. Plain HTML forms; a session cookie says who is logged in, and every form carries
--  the session's CSRF token. An event stream tells open pages when someone posts.
--
--     GET  /                          the threads, newest activity first; a form for a new one
--     GET  /threads/:id               a thread's posts and a reply form
--     POST /threads                   start one: title, body
--     POST /threads/:id/replies       reply: body
--     GET  /register  POST /register  name, password
--     GET  /login     POST /login     name, password
--     POST /logout
--     GET  /events                    Server-Sent Events: "thread" and "reply" (data: the thread's id)
--     GET  /static/*file
with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Forum_Pages is

   --  Compile every template of Directory; Program_Error when one does not compile.
   procedure Load_Views (Directory : String);

   procedure Open_Connection (Worker : Worker_Id);
   procedure Close_Connection (Worker : Worker_Id);

   procedure Home (Request : Http_Request; Response : in out Http_Response);
   procedure Show_Thread (Request : Http_Request; Response : in out Http_Response);
   procedure New_Thread (Request : Http_Request; Response : in out Http_Response);
   procedure Reply (Request : Http_Request; Response : in out Http_Response);
   procedure Register_Form (Request : Http_Request; Response : in out Http_Response);
   procedure Register (Request : Http_Request; Response : in out Http_Response);
   procedure Login_Form (Request : Http_Request; Response : in out Http_Response);
   procedure Login (Request : Http_Request; Response : in out Http_Response);
   procedure Logout (Request : Http_Request; Response : in out Http_Response);
   procedure Events (Request : Http_Request; Response : in out Http_Response);


end Forum_Pages;
