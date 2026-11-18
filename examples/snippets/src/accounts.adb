with Sparrow; use Sparrow;
with Sparrow.Http; use Sparrow.Http;
with Sparrow.Http.Requests; use Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Http.Sessions; use Sparrow.Http.Sessions;
with Sparrow.IO.Process;

package body Accounts is

   --  SESSION_SECRET: 32 random bytes or more (openssl rand -base64 48).
   --  Without it, sessions last until the program restarts.
   Visitors : constant Store :=
     Cookie_Store
       (Secret => Sparrow.IO.Process.Environment
                    ("SESSION_SECRET", Default => Random_Secret));

   --  Look the user up in your database, and check with Password_Hashes.
   function Password_Is_Right (Email, Password : String) return Boolean is
     (Email /= "" and then Password /= "");

   procedure Show_Login
     (Request : Http_Request; Response : in out Http_Response)
   is
      Session : Sessions.Session := Visitors.Load (Request);
   begin
      Responses.Send
        (Response, OK,
         "<form method=post action=/login>"
         & UTF8_String (Csrf_Field (Session))
         & "<input name=email> <input name=password type=password>"
         & "<button>Log in</button></form>",
         Media_Type => Text_Html);
      Visitors.Save (Session, Response);   --  the cookie, when it changed
   end Show_Login;

   procedure Log_In
     (Request : Http_Request; Response : in out Http_Response)
   is
      Session : Sessions.Session := Visitors.Load (Request);
   begin
      if not Csrf_Valid (Session, Request) then
         Responses.Fail (Response, Forbidden);
         return;
      end if;
      if not Password_Is_Right
               (Form_Value (Request, "email"), Form_Value (Request, "password"))
      then
         Responses.Redirect (Response, "/login");
         return;
      end if;
      Renew (Session);   --  a new CSRF token at every login
      Set (Session, "user", Form_Text (Request, "email"));
      Visitors.Save (Session, Response);
      Responses.Redirect (Response, "/me");
   end Log_In;

   procedure Show_Me
     (Request : Http_Request; Response : in out Http_Response)
   is
      Session : constant Sessions.Session := Visitors.Load (Request);
   begin
      if Has (Session, "user") then
         Responses.Send
           (Response, OK, "Signed in as " & Get (Session, "user"));
      else
         Responses.Redirect (Response, "/login");
      end if;
   end Show_Me;

   procedure Log_Out
     (Request : Http_Request; Response : in out Http_Response)
   is
      Session : Sessions.Session := Visitors.Load (Request);
   begin
      if Csrf_Valid (Session, Request) then
         Clear (Session);
         Visitors.Save (Session, Response);
      end if;
      Responses.Redirect (Response, "/login");
   end Log_Out;

   procedure Register (Routes : in out Router) is
   begin
      Add (Routes, Get, "/login", Show_Login'Access);
      Add (Routes, Post, "/login", Log_In'Access);
      Add (Routes, Get, "/me", Show_Me'Access);
      Add (Routes, Post, "/logout", Log_Out'Access);
   end Register;

end Accounts;
