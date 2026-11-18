with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests; use Sparrow.Http.Requests;
with Sparrow.Http.Responses;

package body Greetings is

   --  GET /hello/ada?greeting=Hi  ->  "Hi, ada!"
   procedure Greet
     (Request : Http_Request; Response : in out Http_Response)
   is
      Name     : constant UTF8_String := Parameter_Text (Request, "name");
      Greeting : constant UTF8_String :=
        Query_Text (Request, "greeting", Default => "Hello");
   begin
      Responses.Send (Response, OK, Greeting & ", " & Name & "!");
   end Greet;

   --  GET /items/42  ->  "item 42", or 404 for anything but a number
   procedure Show_Item
     (Request : Http_Request; Response : in out Http_Response)
   is
      Id : constant Long_Long_Integer :=
        Integer_Parameter (Request, "id", Default => -1);
   begin
      if Id < 1 then
         Responses.Fail (Response, Not_Found);
      else
         Responses.Send (Response, OK, "item" & UTF8_String (Id'Image));
      end if;
   end Show_Item;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Get, "/hello/:name", Greet'Access);
      --  On_Reactor: it never blocks, so it need not wait for a worker
      Add (Routes, Get, "/items/:id", Show_Item'Access, Run => On_Reactor);
   end Register;

end Greetings;
