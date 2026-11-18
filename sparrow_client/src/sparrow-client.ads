--  Outbound HTTP/1.1 and HTTPS: calling other services (OAuth token endpoints, payment providers, webhooks,
--  APIs) from a handler. Certificates are checked against the system's trust store, and the host name against
--  the certificate. Each call opens its own connection and closes it. It asks for no compression, and uses no
--  proxy.
--
--  Every call blocks until the answer is in (or Settings.Timeout passes): call it from handlers that run on
--  workers, never on a reactor. Calls from different tasks run in parallel.
--
--  Request_Error is raised when there is no answer: the URL or a header line is malformed, the name does not
--  resolve, the connection or TLS fails, the time runs out, the answer is malformed or cut short, or it is
--  larger than Settings.Max_Response. An answer of any status (404, 500) is not an error: check Status.
private with Ada.Finalization;
private with Sparrow.Buffers;
private with Sparrow.Client_Wire;

package Sparrow.Client is

   type Path_Access is access constant String;

   type Settings is record
      Timeout          : Positive := 30_000;           --  milliseconds for the whole exchange
      Connect_Timeout  : Positive := 10_000;           --  milliseconds to connect, TLS included
      Max_Response     : Positive := 16 * 1_048_576;   --  bytes of content
      Follow_Redirects : Boolean := False;             --  up to Max_Redirects, and only to http and https
      Trust_File       : Path_Access := null;   --  PEM certificates to trust instead of the system's
   end record;

   --  Followed with Follow_Redirects: 301, 302 and 303 as GET without content (a HEAD stays HEAD), 307 and
   --  308 as sent. Headers go only to the origin they were given for: a redirect to another scheme, host or
   --  port drops them.
   Max_Redirects : constant := 5;

   Default_Settings : constant Settings := (others => <>);

   type Response is limited private;

   --  The status of the answer (the last one, after redirects).
   function Status (This : Response) return Natural;

   --  The HTTP the answer came in: 10 or 11.
   function Version (This : Response) return Natural;

   --  The answer's content as it came: compressed, when Headers asked for a compression.
   function Content (This : Response) return String;

   --  The value of the answer's header Name (any case); "" when it has none.
   function Header (This : Response; Name : String) return String;

   --  Headers is extra request headers, one per line ("Authorization: Bearer abc" & ASCII.LF & ...). The
   --  client writes Host, Content-Length and Connection itself, and User-Agent and Accept unless Headers has
   --  them.
   procedure Get
     (Url      : String;
      Answer   : out Response;
      Headers  : String := "";
      Using    : Settings := Default_Settings);

   procedure Post
     (Url        : String;
      Content    : String;
      Answer     : out Response;
      Media_Type : String := "application/json";
      Headers    : String := "";
      Using      : Settings := Default_Settings);

   --  Any method ("PUT", "PATCH", "DELETE", "HEAD"); Content is sent when not empty.
   procedure Send
     (Method     : String;
      Url        : String;
      Answer     : out Response;
      Content    : String := "";
      Media_Type : String := "application/json";
      Headers    : String := "";
      Using      : Settings := Default_Settings);

   Request_Error : exception;

   ---------------------------------------------------------------------------------------------------------------
   --  application/x-www-form-urlencoded, for OAuth and most payment APIs.

   Form_Media_Type : constant String := "application/x-www-form-urlencoded";

   --  Text percent-encoded for a URL's query or a form.
   function Url_Encode (Text : String) return String;

   --  "name=value", both encoded; join pairs with "&".
   function Form_Pair (Name, Value : String) return String is (Url_Encode (Name) & "=" & Url_Encode (Value));

private

   type Response is new Ada.Finalization.Limited_Controlled with record
      Status  : Natural := 0;
      Version : Natural := 0;
      Head    : Sparrow.Buffers.Buffer;   --  the last answer's head, as it came
      Parsed  : Client_Wire.Response_Head;   --  spans of Head
      Content : Sparrow.Buffers.Buffer;
   end record;

   overriding procedure Finalize (This : in out Response);

end Sparrow.Client;
