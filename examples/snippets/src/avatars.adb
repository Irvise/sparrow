with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Multipart; use Sparrow.Http.Multipart;
with Sparrow.Http.Responses;

package body Avatars is

   --  <form method=post enctype=multipart/form-data>
   --    <input name=user> <input type=file name=avatar>
   procedure Upload
     (Request : Http_Request; Response : in out Http_Response)
   is
      Fields : Form;
      Valid  : Boolean;
   begin
      Parse (Request, Fields, Valid);
      if not Valid or else not Has_File (Fields, "avatar") then
         Responses.Fail (Response, Bad_Request);
         return;
      end if;
      --  Choose the path yourself: never trust the client's file name.
      Save (Fields, "avatar",
            "uploads/" & String (Field (Fields, "user")) & ".png");
      Responses.Send (Response, Created, "saved");
   end Upload;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Post, "/avatar", Upload'Access);
   end Register;

end Avatars;
