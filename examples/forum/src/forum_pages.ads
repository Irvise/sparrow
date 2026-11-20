--  The pages of the forum, laid out as a phpBB 2 bulletin board so that a phpBB 2 style folder can dress it.
--  Plain HTML forms; a session cookie says who is logged in, and every form carries the session's CSRF token.
--  An event stream tells open pages when someone posts.
--
--     GET  /                          the forum index: categories, their forums, the last post in each
--     GET  /boards/:id                a forum's topics, newest activity first, page by page; a new-topic form
--     POST /boards/:id/threads        start a topic there: title, body
--     GET  /threads/:id               a topic's posts page by page, with a reply form ("quote" fills it)
--     POST /threads/:id/replies       reply: body
--     GET  /members                   every member with rank, joining date and post count
--     GET  /register  POST /register  name, password
--     GET  /login     POST /login     name, password
--     POST /logout
--     GET  /events                    Server-Sent Events: "thread" and "reply" (data: the thread's id)
--     GET  /static/*file
--     GET  /style/*file               the style folder
with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Forum_Pages is

   --  Compile every template of Directory; Program_Error when one does not compile.
   procedure Load_Views (Directory : String);

   --  The style folder: FORUM_STYLE, or forum/styles/classic. Pages link its stylesheet, named after the
   --  folder (classic/classic.css), and the images in its images folder by their phpBB 2 names.
   function Style_Folder return String;

   procedure Open_Connection (Worker : Worker_Id);
   procedure Close_Connection (Worker : Worker_Id);

   procedure Home (Request : Http_Request; Response : in out Http_Response);
   procedure Show_Board (Request : Http_Request; Response : in out Http_Response);
   procedure Show_Thread (Request : Http_Request; Response : in out Http_Response);
   procedure Members (Request : Http_Request; Response : in out Http_Response);
   procedure New_Thread (Request : Http_Request; Response : in out Http_Response);
   procedure Reply (Request : Http_Request; Response : in out Http_Response);
   procedure Register_Form (Request : Http_Request; Response : in out Http_Response);
   procedure Register (Request : Http_Request; Response : in out Http_Response);
   procedure Login_Form (Request : Http_Request; Response : in out Http_Response);
   procedure Login (Request : Http_Request; Response : in out Http_Response);
   procedure Logout (Request : Http_Request; Response : in out Http_Response);
   procedure Events (Request : Http_Request; Response : in out Http_Response);

end Forum_Pages;
