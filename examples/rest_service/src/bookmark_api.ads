--  A bookmarks API over SQLite: JSON in and out, reads open to all, writes behind an HS256 bearer token.
--
--     GET    /api/bookmarks?q=ada&limit=20      list, newest first; q searches titles and URLs
--     GET    /api/bookmarks/:id                 one
--     POST   /api/bookmarks                     {"url": ..., "title": ..., "note": ...}   201 + Location
--     PUT    /api/bookmarks/:id                 the same fields, replacing them
--     DELETE /api/bookmarks/:id                 204
--
--  Errors are {"error": "..."} with 400, 401, 404, 415 or 422.
with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Routers; use Sparrow.Http.Routers;

package Bookmark_Api is

   --  The secret tokens are signed with; set it before the server runs.
   procedure Set_Secret (Secret : String);

   --  A token for Subject, valid for an hour, to try the write routes with.
   function Demo_Token (Subject : UTF8_String) return String;

   --  Worker hooks: each worker task opens its own connection to DATABASE (default bookmarks.db), creating the
   --  table if it is missing.
   procedure Open_Connection (Worker : Worker_Id);
   procedure Close_Connection (Worker : Worker_Id);

   procedure List (Request : Http_Request; Response : in out Http_Response);
   procedure Show (Request : Http_Request; Response : in out Http_Response);
   procedure Create (Request : Http_Request; Response : in out Http_Response);
   procedure Replace (Request : Http_Request; Response : in out Http_Response);
   procedure Remove (Request : Http_Request; Response : in out Http_Response);

   --  For /readyz (Sparrow.Http.Health): whether this worker's database answers.
   function Database_Ready (Request : Http_Request) return Boolean;

end Bookmark_Api;
