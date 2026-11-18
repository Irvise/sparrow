with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;

package body Hello_Pages is

   procedure Greet (Request : Http_Request; Response : in out Http_Response) is
      Name : constant UTF8_String := Requests.Parameter_Text (Request, "name");
   begin
      Responses.Send (Response, OK, "Hello, " & Name & "!");
   end Greet;

end Hello_Pages;
