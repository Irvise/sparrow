--  IP addresses of both families and their text forms: dotted quads ("192.168.0.1"), and IPv6 read in any
--  RFC 4291 form ("2001:DB8:0:0::1", "::ffff:192.0.2.1", "[::1]") and written in the one RFC 5952 form
--  ("2001:db8::1").
--
--  SPARK: parsing is total (text that is not an address gives Valid = False) and nothing here raises.
with Interfaces; use Interfaces;

package Sparrow.IO.Addresses with SPARK_Mode is

   type Address_Family is (Version_4, Version_6);

   type Byte_Array is array (Positive range <>) of Unsigned_8;

   type IP_Address is private;   --  "=" compares family and address

   Any_IPv4      : constant IP_Address;   --  0.0.0.0, every IPv4 interface
   Any_IPv6      : constant IP_Address;   --  ::, every interface; a listener on it takes IPv4 clients too
   Loopback      : constant IP_Address;   --  127.0.0.1
   Loopback_IPv6 : constant IP_Address;   --  ::1

   function Family_Of (Address : IP_Address) return Address_Family;

   function IPv4 (First, Second, Third, Fourth : Unsigned_8) return IP_Address
      with Post => Family_Of (IPv4'Result) = Version_4;

   --  The address in network order: 4 bytes for IPv4, 16 for IPv6.
   function Bytes (Address : IP_Address) return Byte_Array
      with Post => Bytes'Result'First = 1
                   and then Bytes'Result'Length = (if Family_Of (Address) = Version_4 then 4 else 16);

   function From_Bytes (Raw : Byte_Array) return IP_Address
      with Pre  => Raw'Length in 4 | 16,
           Post => Family_Of (From_Bytes'Result) = (if Raw'Length = 4 then Version_4 else Version_6);

   --  0.0.0.0 or ::.
   function Is_Any (Address : IP_Address) return Boolean;

   --  An IPv4 client seen through a dual-stack listener arrives as ::ffff:a.b.c.d; this gives back a.b.c.d.
   --  Any other address is returned as it is.
   function Unmapped (Address : IP_Address) return IP_Address;

   --  A dotted quad, or IPv6 text, optionally in brackets. Zone suffixes ("%eth0") are refused.
   procedure Parse_Address (Text : String; Address : out IP_Address; Valid : out Boolean)
      with Global => null;

   --  "192.168.0.1", "2001:db8::1", "::ffff:192.0.2.1".
   function Image (Address : IP_Address) return String
      with Post => Image'Result'First = 1 and then Image'Result'Length <= 39;

private

   subtype Sixteen_Bytes is Byte_Array (1 .. 16);

   --  An IPv4 address is held in Raw (1 .. 4), the rest zero, so that "=" is the comparison of addresses.
   type IP_Address is record
      Family : Address_Family := Version_4;
      Raw    : Sixteen_Bytes := [others => 0];
   end record;

   Any_IPv4      : constant IP_Address := (Family => Version_4, Raw => [others => 0]);
   Any_IPv6      : constant IP_Address := (Family => Version_6, Raw => [others => 0]);
   Loopback      : constant IP_Address := (Family => Version_4, Raw => [1 => 127, 4 => 1, others => 0]);
   Loopback_IPv6 : constant IP_Address := (Family => Version_6, Raw => [16 => 1, others => 0]);

   function Family_Of (Address : IP_Address) return Address_Family is (Address.Family);

end Sparrow.IO.Addresses;
