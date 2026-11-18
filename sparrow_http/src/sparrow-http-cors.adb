with Sparrow.Encoding;
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;

package body Sparrow.Http.Cors is

   function Listed (Origin, Allowed : String) return Boolean is
      Start : Positive := Allowed'First;
   begin
      if Origin'Length = 0 then
         return False;
      elsif Allowed = "*" then
         return True;
      end if;
      for Index in Allowed'First .. Allowed'Last + 1 loop
         if Index > Allowed'Last or else Allowed (Index) = ' ' then
            if Index > Start and then Allowed (Start .. Index - 1) = Origin then   --  origins compare exactly
               return True;
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return False;
   end Listed;

   function Allow
     (Origins     : String;
      Methods     : String := "GET, POST, PUT, PATCH, DELETE";
      Headers     : String := "Content-Type, Authorization";
      Exposed     : String := "";
      Credentials : Boolean := False;
      Max_Age     : Natural := 600) return Policy
   is begin
      if Credentials and then Origins = "*" then
         raise Program_Error with "CORS: credentials cannot be allowed to every origin";
      end if;
      return (Origins     => new String'(Origins),
              Methods     => new String'(Methods),
              Headers     => new String'(Headers),
              Exposed     => new String'(Exposed),
              Credentials => Credentials,
              Max_Age     => Max_Age);
   end Allow;

   procedure Apply (This : Policy; Request : Http_Request; Response : in out Http_Response) is
      Origin : constant String := Requests.Header (Request, "Origin");
   begin
      Responses.Set_Header (Response, "Vary", "Origin");   --  caches must keep answers per origin
      if not Listed (Origin, This.Origins.all) then
         return;
      end if;
      Responses.Set_Header (Response, "Access-Control-Allow-Origin",
                            (if This.Origins.all = "*" and then not This.Credentials then "*" else Origin));
      if This.Credentials then
         Responses.Set_Header (Response, "Access-Control-Allow-Credentials", "true");
      end if;
      if This.Exposed'Length > 0 then
         Responses.Set_Header (Response, "Access-Control-Expose-Headers", This.Exposed.all);
      end if;
   end Apply;

   function Preflight (This : Policy'Class) return Preflight_Route is ((Rules => Policy (This)));

   overriding procedure Handle (This : Preflight_Route; Request : Http_Request; Response : in out Http_Response) is
   begin
      Responses.Clear (Response);
      Response.Status := No_Content;
      Apply (This.Rules, Request, Response);
      if Listed (Requests.Header (Request, "Origin"), This.Rules.Origins.all) then
         Responses.Set_Header (Response, "Access-Control-Allow-Methods", This.Rules.Methods.all);
         Responses.Set_Header (Response, "Access-Control-Allow-Headers", This.Rules.Headers.all);
         Responses.Set_Header (Response, "Access-Control-Max-Age",
                               Encoding.Decimal_Image (Long_Long_Integer (This.Rules.Max_Age)));
      end if;
   end Handle;

   function Share (This : Policy'Class; Action : not null Handler) return Shared_Route is
     ((Rules => Policy (This), Action => Action));

   overriding procedure Handle (This : Shared_Route; Request : Http_Request; Response : in out Http_Response) is
   begin
      This.Action (Request, Response);
      Apply (This.Rules, Request, Response);
   end Handle;

end Sparrow.Http.Cors;
