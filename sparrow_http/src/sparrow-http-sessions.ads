--  Sessions, kept one of two ways, and protection against cross-site request forgery: every session carries a
--  random token that forms and scripts send back.
--
--    Cookie_Store: the session is sealed (AES-256-GCM, under the server's secret) into a cookie. The browser
--                  holds it but can neither read nor change it, and the server keeps nothing.
--    Table_Store:  the cookie holds only a random id; the session lives in a Session_Table (your database, or
--                  Memory_Table). Sessions can then be ended from the server: Revoke_User.
--
--     Visitors : constant Sessions.Store := Sessions.Cookie_Store (Secret => Environment ("SESSION_SECRET"));
--
--     procedure Show (Request : Http_Request; Response : in out Http_Response) is
--        Session : Sessions.Session := Visitors.Load (Request);
--     begin
--        if Requests.Verb (Request) = Post and then not Sessions.Csrf_Valid (Session, Request) then
--           Responses.Fail (Response, Forbidden);
--           return;
--        end if;
--        Sessions.Set (Session, "user", "42");
--        ...
--        Visitors.Save (Session, Response);   --  sends the cookie when the session changed
--     end Show;
--
--  Keep cookie sessions small: the cookie travels with every request and browsers refuse ones past about 4 KB
--  (Save raises Too_Large). A cookie session cannot be ended on the server before it expires, except by
--  changing the secret, or with a generation: see Set_Generation.
with Sparrow.Http.Requests;
with Sparrow.Http.Responses;
with Sparrow.Stores;
private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Containers.Indefinite_Ordered_Maps;
private with Ada.Strings.Hash;
private with Sparrow.Buffers;
private with Sparrow.Crypto.Ciphers;

package Sparrow.Http.Sessions is

   type Session is private;

   --  The value stored under Name; Default when there is none.
   function Get (This : Session; Name : String; Default : UTF8_String := "") return UTF8_String;
   function Has (This : Session; Name : String) return Boolean;

   procedure Set (This : in out Session; Name : String; Value : UTF8_String);
   procedure Remove (This : in out Session; Name : String);

   --  Forget everything (log out) and draw a new CSRF token (and, in a table, a new id).
   procedure Clear (This : in out Session);

   --  Keep the values but draw a new CSRF token, and in a table a new id: call it when the user logs in, so a
   --  token or id seen before (in a page cached on a shared computer, say) is no longer good.
   procedure Renew (This : in out Session);

   --  Ending cookie sessions early: keep a counter per user in your database (one indexed column), put it in
   --  the session at login with Set_Generation, and call Check_Generation with the stored counter on each
   --  request. Adding one to a user's counter logs out every session of that user ("log out everywhere").
   procedure Set_Generation (This : in out Session; Generation : Natural);
   function Generation (This : Session) return Natural;   --  0 when never set

   --  Clear This (log it out) unless its generation is Current.
   procedure Check_Generation (This : in out Session; Current : Natural);

   ---------------------------------------------------------------------------------------------------------------
   --  Cross-site request forgery: another site's page can make the browser POST to yours, with your cookies,
   --  but cannot read your pages to learn the token. Put the token in every form (Csrf_Field) or send it as
   --  the X-CSRF-Token header (htmx: hx-headers), and check it on every request that changes something.

   function Csrf_Token (This : Session) return String;

   --  <input type="hidden" name="csrf_token" value="...">
   function Csrf_Field (This : Session) return String;

   --  Whether Request carries this session's token, in the X-CSRF-Token header or the csrf_token form field.
   function Csrf_Valid (This : Session; Request : Requests.Request) return Boolean;

   Too_Large : exception;

   --  A random secret, for development: sessions end whenever the program restarts.
   function Random_Secret return String;

   ---------------------------------------------------------------------------------------------------------------
   --  Where sessions live, for Table_Store: see Sparrow.Stores, where the interface is declared so that a
   --  table (sparrow_valkey's, say) need not depend on this crate. Implement it over your database.
   subtype Session_Table is Stores.Session_Table;
   subtype Session_Table_Access is Stores.Session_Table_Access;

   --  A Session_Table in this process's memory: sessions end when the program restarts, and each server of
   --  several keeps its own. For development, and for single servers that can live with that.
   type Memory_Table is limited new Session_Table with private;
   overriding function Read (This : Memory_Table; Id : String) return String;
   overriding procedure Write
     (This : in out Memory_Table; Id : String; User : String; Data : String; Expires : Long_Long_Integer);
   overriding procedure Delete (This : in out Memory_Table; Id : String);
   overriding procedure Delete_User (This : in out Memory_Table; User : String);
   function Count (This : Memory_Table) return Natural;   --  sessions held, expired ones included

   ---------------------------------------------------------------------------------------------------------------
   --  Where sessions are kept, and how: build one at start-up and share it.
   type Store is tagged private;

   --  Sessions sealed into a cookie. Secret: at least 32 random bytes, kept out of the source (Program_Error
   --  otherwise). Previous_Secret: the secret before, while rotating: sessions sealed with it are still read
   --  (and sealed again with Secret when saved); drop it after Max_Age. Max_Age: seconds, renewed as the
   --  session is used. Secure: browsers treat http://localhost as secure too.
   function Cookie_Store
     (Secret          : String;
      Cookie_Name     : String := "session";
      Max_Age         : Positive := 14 * 24 * 60 * 60;
      Secure          : Boolean := True;
      Same_Site       : Responses.Same_Site_Policy := Responses.Lax;
      Previous_Secret : String := "") return Store;

   --  Sessions kept in Table, which must outlive the store. Max_Age: seconds a session may go unused (its
   --  idle timeout); a session in use is written again once half of it has passed.
   function Table_Store
     (Table       : not null Session_Table_Access;
      Cookie_Name : String := "session";
      Max_Age     : Positive := 14 * 24 * 60 * 60;
      Secure      : Boolean := True;
      Same_Site   : Responses.Same_Site_Policy := Responses.Lax) return Store;

   --  End every session of User (the session value "user"): a Table_Store's sessions only (Program_Error for
   --  a Cookie_Store: use generations).
   procedure Revoke_User (This : Store; User : String);

   --  Request's session, or a new, empty one when it has none (or a forged or expired one).
   function Load (This : Store; Request : Requests.Request) return Session;

   --  Send the session's cookie (and write it to the table) when it changed, is new, or is half way to
   --  expiring.
   procedure Save (This : Store; Item : in out Session; Response : in out Responses.Response);

private

   type Store is tagged record
      Key         : Sparrow.Crypto.Ciphers.Key_Bytes := [others => ASCII.NUL];
      Old_Key     : Sparrow.Crypto.Ciphers.Key_Bytes := [others => ASCII.NUL];
      Has_Old_Key : Boolean := False;
      Table       : Session_Table_Access;   --  null: a Cookie_Store
      Cookie_Name : Sparrow.Buffers.String_Access;
      Max_Age     : Positive := 14 * 24 * 60 * 60;
      Secure      : Boolean := True;
      Same_Site   : Responses.Same_Site_Policy := Responses.Lax;
   end record;

   package Value_Maps is new Ada.Containers.Indefinite_Ordered_Maps (String, String);

   subtype Session_Id is String (1 .. 43);   --  32 random bytes in Base64

   type Session is record
      Values   : Value_Maps.Map;
      Token    : String (1 .. 24) := [others => ' '];   --  the CSRF token, 18 random bytes in Base64
      Issued   : Long_Long_Integer := 0;                --  Unix seconds when the cookie was last sent
      Changed  : Boolean := True;
      Id       : Session_Id := [others => ' '];        --  in a table
      Has_Id   : Boolean := False;
      Old_Id   : Session_Id := [others => ' '];        --  to delete when saved: Renew drew a new one
      Drop_Old : Boolean := False;
   end record;

   type Saved (User_Length, Data_Length : Natural) is record
      User    : String (1 .. User_Length);
      Data    : String (1 .. Data_Length);
      Expires : Long_Long_Integer;
   end record;

   package Saved_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Saved, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   protected type Guarded_Sessions is
      function Read (Id : String; Now : Long_Long_Integer) return String;
      procedure Write (Id : String; Item : Saved; Now : Long_Long_Integer);
      procedure Delete (Id : String);
      procedure Delete_User (User : String);
      function Count return Natural;
   private
      Sessions : Saved_Maps.Map;
      Writes   : Natural := 0;
   end Guarded_Sessions;

   type Memory_Table is limited new Session_Table with record
      Guard : Guarded_Sessions;
   end record;

end Sparrow.Http.Sessions;
