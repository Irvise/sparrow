--  multipart/form-data: HTML forms with file inputs (<form method="post" enctype="multipart/form-data">).
--
--     Upload : Multipart.Form;
--     Valid  : Boolean;
--     ...
--     Multipart.Parse (Request, Upload, Valid);
--     if Valid and then Multipart.Has_File (Upload, "photo") then
--        Multipart.Save (Upload, "photo", "/srv/uploads/" & New_Id & ".jpg");
--     end if;
--     Title := Multipart.Field (Upload, "title");
--
--  Parse needs the whole body in memory, so an upload is bounded by Limits.Max_Body_Length, and a worker holds
--  it twice while parsing it. For large files, add the route with Body_Mode => Streamed and use Save_Stream,
--  which writes file parts to disk as they arrive:
--
--     Multipart.Save_Stream (Request, "/srv/uploads/incoming", Upload, Valid);
--     if Valid and then Multipart.Has_File (Upload, "video") then
--        Multipart.Save (Upload, "video", "/srv/uploads/" & New_Id & ".mp4");   --  moves the file
--     end if;
--     Multipart.Discard (Upload);   --  deletes the files not moved
--
--  Never use a part's File_Name as a path: it comes from the client. Make your own names, and check the
--  content of files you will serve back rather than trusting Content_Type.
with Sparrow.Http.Requests;
private with Ada.Containers.Indefinite_Vectors;

package Sparrow.Http.Multipart is

   type Form is private;

   --  The parts of Request's body; Valid is False when it is not multipart/form-data or is malformed.
   procedure Parse (Request : Requests.Request; Into : out Form; Valid : out Boolean);

   --  Parts by position, 1 .. Part_Count.
   function Part_Count (This : Form) return Natural;
   function Name (This : Form; Index : Positive) return String;
   function File_Name (This : Form; Index : Positive) return String;     --  "" for fields; no directories
   function Content_Type (This : Form; Index : Positive) return String;  --  as the client said
   function Content (This : Form; Index : Positive) return String;

   --  The first part called Name; 0 when there is none.
   function Find (This : Form; Name : String) return Natural;

   --  A text field's value: Default when missing, a file, or not UTF-8.
   function Field (This : Form; Name : String; Default : UTF8_String := "") return UTF8_String;

   --  Whether Name is a file part with something in it (an empty file input sends a part with no file name).
   function Has_File (This : Form; Name : String) return Boolean;

   --  Write part Name's content to Path, replacing what is there; a part Save_Stream wrote to disk is moved
   --  there. Name_Error when there is no such part.
   procedure Save (This : Form; Name : String; Path : String);

   ---------------------------------------------------------------------------------------------------------------
   --  Streamed bodies

   --  The parts of a streamed body (a route added with Body_Mode => Streamed), read as they arrive. A file part
   --  goes to a new file in Directory, named by Sparrow (never by the client), and its Content is ""; text
   --  fields are kept in memory, up to Max_Field_Length bytes each. Valid is False, and the files written so far
   --  are deleted, when the body is not multipart/form-data, is malformed, has more than Max_Parts parts or a
   --  field past Max_Field_Length. Bodies.Body_Error (the client left) deletes them too, and passes through.
   procedure Save_Stream
     (Request          : Requests.Request;
      Directory        : String;
      Into             : out Form;
      Valid            : out Boolean;
      Max_Field_Length : Positive := 65_536;
      Max_Parts        : Positive := 100);

   --  Where Save_Stream wrote part Index, and how many bytes; "" and the content's length for other parts.
   function Saved_Path (This : Form; Index : Positive) return String;
   function Saved_Size (This : Form; Index : Positive) return Long_Long_Integer;

   --  Delete the files Save_Stream wrote that were not moved by Save.
   procedure Discard (This : Form);

   --  The boundary of a multipart Content-Type header value; "" when it has none.
   function Boundary_Of (Content_Type : String) return String;

private

   type Part (Name_Length, File_Length, Type_Length, Content_Length, Path_Length : Natural) is record
      Name         : String (1 .. Name_Length);
      File_Name    : String (1 .. File_Length);
      Content_Type : String (1 .. Type_Length);
      Content      : String (1 .. Content_Length);
      Path         : String (1 .. Path_Length);   --  where Save_Stream wrote it
      Size         : Long_Long_Integer := 0;
   end record;

   package Part_Vectors is new Ada.Containers.Indefinite_Vectors (Positive, Part);

   type Form is record
      Parts : Part_Vectors.Vector;
   end record;

end Sparrow.Http.Multipart;
