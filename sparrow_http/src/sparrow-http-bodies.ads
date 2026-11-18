--  Request bodies read as they arrive, for routes added with Body_Mode => Streamed: uploads larger than memory
--  should hold (videos, backups), written to disk or passed on as they come.
--
--     procedure Upload (Request : Http_Request; Response : in out Http_Response) is
--        Chunk : String (1 .. 65_536);
--        Last  : Natural;
--     begin
--        loop
--           Bodies.Read (Request, Chunk, Last);
--           exit when Last < Chunk'First;   --  the end of the body
--           Ada.Streams.Stream_IO.Write (File, ...Chunk (Chunk'First .. Last)...);
--        end loop;
--        Responses.Send (Response, Created, "stored");
--     end Upload;
--
--     Routers.Add (Routes, Post, "/upload", Upload'Access, Body_Mode => Routers.Streamed);
--
--  Read waits for the client. While the handler does not read, the server stops reading the connection, so a
--  fast client cannot fill memory: at most 64 KiB wait in the server per upload. A body may be sent with a
--  Content-Length or chunked, and may be as long as Limits.Max_Streamed_Length. A handler that answers before
--  reading the whole body may: the connection is closed after its response.
with Sparrow.Http.Requests;

package Sparrow.Http.Bodies is

   --  The client left, sent a malformed chunked body, or passed Limits.Max_Streamed_Length; the message says
   --  which. The handler need not answer: the connection is closed.
   Body_Error : exception;

   --  The next bytes of the body into Into (Into'First .. Last), waiting for them if need be; Last < Into'First
   --  at the end of the body. Raises Body_Error, and Program_Error on a route whose body is not streamed.
   procedure Read (Request : Requests.Request; Into : out String; Last : out Natural);

   --  The whole body as one string, for when it turns out small: Body_Error past Max_Length.
   function Read_All (Request : Requests.Request; Max_Length : Positive) return String;

   --  The Content-Length the client declared; -1 for a chunked body, whose length is known only at its end.
   function Declared_Length (Request : Requests.Request) return Long_Long_Integer;

end Sparrow.Http.Bodies;
