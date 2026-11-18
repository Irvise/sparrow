--  What an HTTP/1.1 client reads: a URL to send a request to, and the head of the response that comes back.
--  Nothing is copied: results are spans of the bytes given.
--
--  SPARK: nothing here can raise or read outside what it is given, on any input, and every span it returns lies
--  inside it.
with Sparrow.Chunked;
with Sparrow.Encoding; use Sparrow.Encoding;

package Sparrow.Client_Wire with SPARK_Mode is

   ---------------------------------------------------------------------------------------------------------------
   --  URLs

   type Port_Number is range 0 .. 65_535;

   Max_Host_Length : constant := 255;

   type Url_Parts (Valid : Boolean := False) is record
      case Valid is
         when True =>
            Secure    : Boolean;       --  https
            Host      : Span;          --  a name or an address; an IPv6 address without its brackets
            Bracketed : Boolean;       --  the host is an IPv6 address
            Port      : Port_Number;   --  the URL's, or its scheme's
            Target    : Span;          --  the path and query; Empty for "/", and missing its '/' before a bare '?'
         when False =>
            null;
      end case;
   end record;

   function Consistent (Parts : Url_Parts; Url : String) return Boolean is
     (not Parts.Valid
      or else (Length (Parts.Host) in 1 .. Max_Host_Length
               and then Within (Parts.Host, Url)
               and then Within (Parts.Target, Url)));

   --  An absolute http or https URL, its scheme in any case. Not valid: another scheme, credentials ("user@"),
   --  an empty host, a host other than a name or an address, port 0 or past 65535, and a space or control byte
   --  in the path or query. A fragment ("#...") is dropped.
   function Split_Url (Url : String) return Url_Parts
      with Pre  => Url'Last < Positive'Last,
           Post => Consistent (Split_Url'Result, Url);

   ---------------------------------------------------------------------------------------------------------------
   --  response heads (RFC 9112 2 to 6)

   Max_Headers : constant := 100;

   type Header is record
      Name  : Span;
      Value : Span;   --  trimmed of surrounding blanks
   end record;

   type Header_Count is range 0 .. Max_Headers;
   subtype Header_Index is Header_Count range 1 .. Max_Headers;
   type Header_List is array (Header_Index) of Header;

   subtype Body_Size is Chunked.Body_Size;

   --  Where the body ends.
   type Body_Framing is
     (No_Body,       --  an answer to HEAD, or a status of 1xx, 204 or 304
      Sized,         --  after Body_Length bytes
      Chunks,        --  chunked: read it with Sparrow.Chunked
      Until_Close);  --  at the end of the connection

   subtype Status_Code is Natural range 100 .. 999;

   type Parse_Outcome is (Complete, Incomplete, Invalid);

   type Response_Head (Outcome : Parse_Outcome := Incomplete) is record
      case Outcome is
         when Complete =>
            Status        : Status_Code;
            Minor_Version : Natural range 0 .. 1;   --  HTTP/1.0 or HTTP/1.1
            Headers       : Header_List;            --  1 .. Header_Total, in the order sent
            Header_Total  : Header_Count;
            Head_Length   : Positive;               --  through the blank line
            Framing       : Body_Framing;
            Body_Length   : Body_Size;              --  when Sized
         when Incomplete | Invalid =>
            null;
      end case;
   end record;

   --  Whether every span of a complete head lies inside Answer.
   function Consistent (Head : Response_Head; Answer : String) return Boolean is
     (Head.Outcome /= Complete
      or else (Head.Head_Length <= Answer'Length
               and then (for all Index in 1 .. Head.Header_Total =>
                            Within (Head.Headers (Index).Name, Answer)
                            and then Within (Head.Headers (Index).Value, Answer))));

   --  Parse the head at the start of Answer; Asked_Head: the request was HEAD, so no body follows. Incomplete
   --  until its blank line arrives. Invalid: longer than Max_Head_Length, more than Max_Headers headers, a
   --  version other than 1.0 and 1.1, a malformed line, a folded header, or a Content-Length that is not one
   --  number.
   function Parse_Head (Answer : String; Asked_Head : Boolean; Max_Head_Length : Positive) return Response_Head
      with Pre  => Answer'Last < Positive'Last - 4,
           Post => Consistent (Parse_Head'Result, Answer);

   --  The value of the first header called Name (compared without case); Empty when there is none.
   function Header_Value (Answer : String; Head : Response_Head; Name : String) return Span
      with Pre  => Head.Outcome = Complete and then Consistent (Head, Answer),
           Post => Within (Header_Value'Result, Answer);

end Sparrow.Client_Wire;
