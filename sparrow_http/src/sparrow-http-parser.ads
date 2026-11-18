--  HTTP/1.1 request heads. The parser copies nothing: it returns spans of the request bytes.
--
--  SPARK: the parser cannot raise or read outside the request on any input, and every span it returns lies
--  inside it.
with Sparrow.Chunked;
with Sparrow.Encoding; use Sparrow.Encoding;

package Sparrow.Http.Parser with SPARK_Mode is

   Max_Headers : constant := 64;

   type Header is record
      Name  : Span;
      Value : Span;   --  trimmed of surrounding blanks
   end record;

   type Header_Count is range 0 .. Max_Headers;
   subtype Header_Index is Header_Count range 1 .. Max_Headers;
   type Header_List is array (Header_Index) of Header;

   subtype Body_Size is Chunked.Body_Size;

   --  Max_Body_Length bounds a body read into memory; Max_Streamed_Length one read as it arrives (a route with
   --  Body_Mode => Streamed). The parser refuses a body longer than both.
   type Limits is record
      Max_Head_Length     : Positive  := 16_384;
      Max_Body_Length     : Natural   := 1_048_576;
      Max_Streamed_Length : Body_Size := 16 * 2 ** 30;
   end record;

   Default_Limits : constant Limits := (others => <>);

   type Parse_Outcome is (Complete, Incomplete, Invalid);

   type Request_Head (Outcome : Parse_Outcome := Incomplete) is record
      case Outcome is
         when Complete =>
            Verb         : Method;
            Verb_Text    : Span;           --  the method as sent (for Other)
            Path         : Span;           --  the target before '?', still percent-encoded
            Query        : Span;           --  after '?', empty when there is none
            Headers      : Header_List;    --  1 .. Header_Total, in the order sent
            Header_Total : Header_Count;
            Head_Length  : Positive;       --  through the blank line
            Body_Length  : Body_Size;      --  Content-Length; 0 when there is none
            Chunked      : Boolean;        --  Transfer-Encoding: chunked; read the body with Sparrow.Chunked
            Keep_Alive   : Boolean;
         when Incomplete =>
            null;                          --  the blank line has not arrived yet: read more
         when Invalid =>
            Status : Status_Code;          --  answer with it, then close
      end case;
   end record;

   --  Whether every span of a complete head lies inside Request.
   function Consistent (Head : Request_Head; Request : String) return Boolean is
     (Head.Outcome /= Complete
      or else (Head.Head_Length <= Request'Length
               and then Within (Head.Verb_Text, Request)
               and then Within (Head.Path, Request)
               and then Within (Head.Query, Request)
               and then (for all Index in 1 .. Head.Header_Total =>
                            Within (Head.Headers (Index).Name, Request)
                            and then Within (Head.Headers (Index).Value, Request))));

   --  Parse the head at the start of Request. Refused as Invalid: a head longer than the limit (431), more
   --  than Max_Headers headers (431), a body longer than both limits (413), a transfer coding other than chunked
   --  (501), both a length and chunked, or anything else malformed (400).
   function Parse_Head (Request : String; Within_Limits : Limits := Default_Limits) return Request_Head
      with Pre  => Request'Last < Positive'Last - 4,
           Post => Consistent (Parse_Head'Result, Request);

   --  The value of the first header called Name (compared without case); Empty when there is none.
   function Header_Value (Request : String; Head : Request_Head; Name : String) return Span
      with Pre  => Head.Outcome = Complete and then Consistent (Head, Request),
           Post => Within (Header_Value'Result, Request);

end Sparrow.Http.Parser;
