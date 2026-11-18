with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Json; use Sparrow.Json;
with Sparrow.Json.Builders;

package body Bookmarks is

   Rules : constant Rule_List :=
     [Required ("url", Text_Shape, Shortest => 1, Longest => 2048),
      Optional ("title", Text_Shape, Longest => 200)];

   --  POST /bookmarks  {"url": "https://ada-lang.io", "title": "Ada"}
   procedure Create
     (Request : Http_Request; Response : in out Http_Response)
   is
      Fields : constant Document := Requests.Json_Body (Request);
      Reply  : Builders.Builder (Response.Content'Access);
   begin
      if not Is_Valid (Fields) then
         Responses.Send (Response, Bad_Request, "the body is not JSON");
         return;
      elsif Problem (Fields, Rules) /= "" then
         --  "url: required", "title: too long", ...
         Responses.Send
           (Response, Unprocessable_Content, Problem (Fields, Rules));
         return;
      end if;

      --  ... store it ...

      Responses.Begin_Content (Response, Created, Application_Json);
      Reply.Begin_Object;
      Reply.Member ("url", Text (Fields, "url"));
      Reply.Member ("title", Text (Fields, "title"));
      Reply.Key ("tags");
      Reply.Begin_Array;
      Reply.Value ("ada");
      Reply.End_Array;
      Reply.End_Object;   --  {"url":"...","title":"Ada","tags":["ada"]}
   end Create;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Post, "/bookmarks", Create'Access);
   end Register;

end Bookmarks;
