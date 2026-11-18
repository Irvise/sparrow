--  multipart/form-data bodies: the input is the body of a request whose head names the boundary "XyZ".
--
--  Properties: parsing returns without raising; every part's file name has no directory in it; a field read
--  by name is the first part of that name when that part is valid UTF-8 text.
with Ada.Strings.Fixed;
with Fuzz_Driver; use Fuzz_Driver;
with Sparrow.Buffers; use Sparrow.Buffers;
with Sparrow.Encoding;
with Sparrow.Http.Multipart; use Sparrow.Http.Multipart;
with Sparrow.Http.Requests;

procedure Fuzz_Multipart is

   CRLF : constant String := ASCII.CR & ASCII.LF;

   procedure Test (Input : String) is
      Length  : constant String := Ada.Strings.Fixed.Trim (Natural'Image (Input'Length), Ada.Strings.Left);
      Request : Sparrow.Http.Requests.Request;
      Bytes   : Buffer;
      Valid   : Boolean;
      Upload  : Form;
   begin
      Append (Bytes, "POST /upload HTTP/1.1" & CRLF & "Host: h" & CRLF
                     & "Content-Type: multipart/form-data; boundary=XyZ" & CRLF
                     & "Content-Length: " & Length & CRLF & CRLF & Input);
      Sparrow.Http.Requests.Load (Request, Bytes, Valid);
      Check (Valid, "the request around the body loads");
      Parse (Request, Upload, Valid);
      if Valid then
         for Index in 1 .. Part_Count (Upload) loop
            declare
               File : constant String := File_Name (Upload, Index);
               Name : constant String := Sparrow.Http.Multipart.Name (Upload, Index);
            begin
               Check (Ada.Strings.Fixed.Index (File, "/") = 0 and then Ada.Strings.Fixed.Index (File, "\") = 0,
                      "a file name has no directory");
               Check (Find (Upload, Name) in 1 .. Index, "Find gives the first part of a name");
               if Find (Upload, Name) = Index and then File = ""
                 and then Sparrow.Encoding.Valid_Utf8 (Content (Upload, Index))
               then
                  Check (String (Field (Upload, Name, Default => "<none>")) = Content (Upload, Index),
                         "a text field reads as its content");
               end if;
            end;
         end loop;
      end if;
      Sparrow.Http.Requests.Free (Request);
      Free (Bytes);
   end Test;

   procedure Fuzz is new Run (Test);

begin
   Fuzz;
end Fuzz_Multipart;
