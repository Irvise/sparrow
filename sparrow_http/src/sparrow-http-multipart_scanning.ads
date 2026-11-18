--  The parts of multipart/form-data (RFC 7578) that read the client's bytes: finding delimiters, reading a
--  part's header lines, and the parameters of a header value. Results are spans of the text given, never
--  copies, so Sparrow.Http.Multipart decides what to keep.
--
--  SPARK: no run-time errors, and every span returned lies inside the text it describes.
with Sparrow.Encoding; use Sparrow.Encoding;

package Sparrow.Http.Multipart_Scanning with SPARK_Mode is

   --  The largest index the scanner accepts, leaving room to step past the end.
   Max_Index : constant := Positive'Last - 8;

   --  Where Pattern first starts in Text, or 0.
   function Find (Text, Pattern : String) return Natural
      with Pre  => Pattern'Length > 0 and then Text'Last <= Max_Index,
           Post => Find'Result = 0
                   or else (Find'Result in Text'Range and then Find'Result <= Text'Last - Pattern'Length + 1
                            and then Text (Find'Result .. Find'Result + Pattern'Length - 1) = Pattern);

   --  Where the value of parameter Key (lower case; matched without regard to case) lies in a header value like
   --  form-data; name="a"; filename="b". A quoted value runs to the closing quote (browsers escape quotes in
   --  names as %22); a bare one to the next ';', without spaces at either end. Empty when there is none.
   function Parameter (Value, Key : String) return Span
      with Pre  => Value'Last <= Max_Index,
           Post => Within (Parameter'Result, Value);

   --  What a part's header lines say: its Content-Disposition name and file name (only its last path segment:
   --  old browsers send whole Windows paths), and its Content-Type. Each is Empty when absent.
   type Part_Head is record
      Name, File_Name, Kind : Span := Empty;
   end record;

   --  Head: the part's header lines, CRLF between them, without the blank line after them.
   function Read_Head (Head : String) return Part_Head
      with Pre  => Head'Last <= Max_Index,
           Post => Within (Read_Head'Result.Name, Head) and then Within (Read_Head'Result.File_Name, Head)
                   and then Within (Read_Head'Result.Kind, Head);

   type Step_Kind is (Part_Found, Closed, Malformed);

   type Step is record
      Kind    : Step_Kind := Malformed;
      Head    : Span := Empty;   --  Part_Found: the part's header lines, for Read_Head
      Content : Span := Empty;   --  Part_Found: its content
      Next    : Positive := 1;   --  Part_Found: where the next delimiter's Marker starts
   end record;

   --  The part after the delimiter whose Marker ("--" & boundary) starts at Position: Closed when it is the
   --  closing delimiter, Malformed when the body breaks off or breaks the format.
   function Next_Part (Data, Marker : String; Position : Positive) return Step
      with Pre  => Marker'Length in 1 .. 80 and then Data'Length >= Marker'Length and then Data'Last <= Max_Index
                   and then Position >= Data'First
                   and then Position <= Data'Last - Marker'Length + 1,
           Post => (if Next_Part'Result.Kind = Part_Found
                    then Within (Next_Part'Result.Head, Data) and then Within (Next_Part'Result.Content, Data)
                         and then Next_Part'Result.Next > Position
                         and then Next_Part'Result.Next <= Data'Last - Marker'Length + 1);

end Sparrow.Http.Multipart_Scanning;
