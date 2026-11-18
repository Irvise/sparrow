--  struct sockaddr_in and sockaddr_in6 as bytes, for the socket bodies of every platform. The layouts agree
--  everywhere but in two places, which the platform passes in: the number of AF_INET6, and whether a length
--  byte comes before the family (the BSDs) or the family takes two bytes (Linux, Windows).
--
--     sockaddr_in    family 2 | port 2 | address 4 | zero 8                       16 bytes
--     sockaddr_in6   family 2 | port 2 | flow 4 | address 16 | scope 4             28 bytes
--
--  Ports and addresses are in network order; the family, where it takes two bytes, is little-endian (every
--  platform Sparrow runs on is).
with Interfaces; use Interfaces;
with Sparrow.IO.Addresses; use Sparrow.IO.Addresses;

private package Sparrow.IO.Socket_Storage with SPARK_Mode is

   AF_INET : constant := 2;

   type Layout is record
      Inet6_Family : Unsigned_8;   --  AF_INET6
      Length_Byte  : Boolean;      --  sin_len before an 8-bit family
   end record;

   --  struct sockaddr_storage (declare objects of it with Alignment => 8)
   subtype Storage is Byte_Array (1 .. 128);

   procedure Encode
     (Address : IP_Address; Port : Unsigned_16; Using : Layout; Into : out Storage; Length : out Positive)
      with Post => Length in 16 | 28;

   --  Known is False for any family but the two.
   procedure Decode
     (From : Storage; Using : Layout; Address : out IP_Address; Port : out Unsigned_16; Known : out Boolean);

   --  The socket family to open for Address.
   function Family_Code (Address : IP_Address; Using : Layout) return Unsigned_8 is
     (if Family_Of (Address) = Version_4 then AF_INET else Using.Inet6_Family);

end Sparrow.IO.Socket_Storage;
