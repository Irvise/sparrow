--  The constant tables of HPACK (RFC 7541): the static table (Appendix A) and the Huffman code (Appendix B).
--  Taken from the RFC's text; tests/src/http_2_tests.adb checks them against the RFC's examples (Appendix C).
package Sparrow.Http.Hpack_Tables with SPARK_Mode is

   ---------------------------------------------------------------------------------------------------------------
   --  The static table: entry Index's name is Static_Text (Name_First .. Name_Last), its value
   --  Static_Text (Value_First .. Value_Last) ("" when Value_Last < Value_First).

   Static_Text : constant String :=
     ":authority:methodGET:methodPOST:path/:path/index.html:schemehttp:schemehttps:status200:sta"
     & "tus204:status206:status304:status400:status404:status500accept-charsetaccept-encodinggzip,"
     & " deflateaccept-languageaccept-rangesacceptaccess-control-allow-originageallowauthorization"
     & "cache-controlcontent-dispositioncontent-encodingcontent-languagecontent-lengthcontent-loca"
     & "tioncontent-rangecontent-typecookiedateetagexpectexpiresfromhostif-matchif-modified-sincei"
     & "f-none-matchif-rangeif-unmodified-sincelast-modifiedlinklocationmax-forwardsproxy-authenti"
     & "cateproxy-authorizationrangerefererrefreshretry-afterserverset-cookiestrict-transport-secu"
     & "ritytransfer-encodinguser-agentvaryviawww-authenticate";

   type Static_Entry is record
      Name_First, Name_Last, Value_First, Value_Last : Natural;
   end record;

   Static_Size : constant := 61;
   type Static_Index is range 1 .. Static_Size;

   Static_Entries : constant array (Static_Index) of Static_Entry :=
     [(1, 10, 11, 10), (11, 17, 18, 20), (21, 27, 28, 31), (32, 36, 37, 37), (38, 42, 43, 53), (54, 60, 61, 64),
      (65, 71, 72, 76), (77, 83, 84, 86), (87, 93, 94, 96), (97, 103, 104, 106), (107, 113, 114, 116),
      (117, 123, 124, 126), (127, 133, 134, 136), (137, 143, 144, 146), (147, 160, 161, 160), (161, 175, 176, 188),
      (189, 203, 204, 203), (204, 216, 217, 216), (217, 222, 223, 222), (223, 249, 250, 249), (250, 252, 253, 252),
      (253, 257, 258, 257), (258, 270, 271, 270), (271, 283, 284, 283), (284, 302, 303, 302), (303, 318, 319, 318),
      (319, 334, 335, 334), (335, 348, 349, 348), (349, 364, 365, 364), (365, 377, 378, 377), (378, 389, 390, 389),
      (390, 395, 396, 395), (396, 399, 400, 399), (400, 403, 404, 403), (404, 409, 410, 409), (410, 416, 417, 416),
      (417, 420, 421, 420), (421, 424, 425, 424), (425, 432, 433, 432), (433, 449, 450, 449), (450, 462, 463, 462),
      (463, 470, 471, 470), (471, 489, 490, 489), (490, 502, 503, 502), (503, 506, 507, 506), (507, 514, 515, 514),
      (515, 526, 527, 526), (527, 544, 545, 544), (545, 563, 564, 563), (564, 568, 569, 568), (569, 575, 576, 575),
      (576, 582, 583, 582), (583, 593, 594, 593), (594, 599, 600, 599), (600, 609, 610, 609), (610, 634, 635, 634),
      (635, 651, 652, 651), (652, 661, 662, 661), (662, 665, 666, 665), (666, 668, 669, 668), (669, 684, 685, 684)];

   ---------------------------------------------------------------------------------------------------------------
   --  The Huffman code, which is canonical: the codes of one length are consecutive numbers, and each length's
   --  first code follows from the shorter ones. The codes of length L are First_Code (L) ..
   --  First_Code (L) + Code_Count (L) - 1, for the symbols By_Code (First_Symbol (L) ..), in order. Symbol 256
   --  is EOS, which never appears in a valid string.

   subtype Code_Length is Positive range 5 .. 30;
   subtype Symbol is Natural range 0 .. 256;
   End_Of_String : constant Symbol := 256;

   First_Code   : constant array (Code_Length) of Natural :=
     [0, 20, 92, 248, 0, 1016, 2042, 4090, 8184, 16380, 32764, 0, 0, 0, 524272, 1048550, 2097116, 4194258, 8388568,
      16777194, 33554412, 67108832, 134217694, 268435426, 0, 1073741820];
   Code_Count   : constant array (Code_Length) of Symbol :=
     [10, 26, 32, 6, 0, 5, 3, 2, 6, 2, 3, 0, 0, 0, 3, 8, 13, 26, 29, 12, 4, 15, 19, 29, 0, 4];
   First_Symbol : constant array (Code_Length) of Symbol :=
     [0, 10, 36, 68, 0, 74, 79, 82, 84, 90, 92, 0, 0, 0, 95, 98, 106, 119, 145, 174, 186, 190, 205, 224, 0, 253];
   By_Code      : constant array (Symbol) of Symbol :=
     [48, 49, 50, 97, 99, 101, 105, 111, 115, 116, 32, 37, 45, 46, 47, 51, 52, 53, 54, 55, 56, 57, 61, 65, 95, 98,
      100, 102, 103, 104, 108, 109, 110, 112, 114, 117, 58, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79,
      80, 81, 82, 83, 84, 85, 86, 87, 89, 106, 107, 113, 118, 119, 120, 121, 122, 38, 42, 44, 59, 88, 90, 33, 34, 40,
      41, 63, 39, 43, 124, 35, 62, 0, 36, 64, 91, 93, 126, 94, 125, 60, 96, 123, 92, 195, 208, 128, 130, 131, 162,
      184, 194, 224, 226, 153, 161, 167, 172, 176, 177, 179, 209, 216, 217, 227, 229, 230, 129, 132, 133, 134, 136,
      146, 154, 156, 160, 163, 164, 169, 170, 173, 178, 181, 185, 186, 187, 189, 190, 196, 198, 228, 232, 233, 1, 135,
      137, 138, 139, 140, 141, 143, 147, 149, 150, 151, 152, 155, 157, 158, 165, 166, 168, 174, 175, 180, 182, 183,
      188, 191, 197, 231, 239, 9, 142, 144, 145, 148, 159, 171, 206, 215, 225, 236, 237, 199, 207, 234, 235, 192, 193,
      200, 201, 202, 205, 210, 213, 218, 219, 238, 240, 242, 243, 255, 203, 204, 211, 212, 214, 221, 222, 223, 241,
      244, 245, 246, 247, 248, 250, 251, 252, 253, 254, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21,
      23, 24, 25, 26, 27, 28, 29, 30, 31, 127, 220, 249, 10, 13, 22, 256];

end Sparrow.Http.Hpack_Tables;
