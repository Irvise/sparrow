--  Keys, a JWKS and tokens made with Python's cryptography package by tests/jwt_vectors.py, for checking
--  Sparrow's signatures against another implementation. Test keys only; run it again to make new ones.
package Jwt_Vectors is

   Jwks : constant String :=
     "{""keys"":[{""kty"":""RSA"",""kid"":""rsa1"",""use"":""sig"",""alg"":""RS256"",""n"":""n9CL"
     & "o34XeXorf7C7sHNv1SrjPG8lIjk6zPysbRrAyL54wyzEyVu6W5bYrZMtQ0gNFYctjQcqCB"
     & "NWHaDa2X47jKrw0czottVW5U5FUO9k5jl6TUgD8R0lRKoaT6q-Lz8FbDBsuh1aqwWGxNcg"
     & "LofYAtcwtM6HYkWoGE1Thfsr7-zIALVrUwz7yHoHdQGWkIp0Bdsc-qRw-b98gacIsFNROh"
     & "J635sABBlx1dYXBc0drwIwFPguwk_U09CyuuC5CbPnzGQtiXL8a4gpRGpSS7EvgLgs8rAi"
     & "xFGYOz-gOKD5smmwZCK-AvYLRQvt1Wc7l1YYyrK2moUTpGjjwlT4apWqWQ"",""e"":""AQAB"""
     & "},{""kty"":""EC"",""kid"":""ec1"",""crv"":""P-256"",""x"":""grz08ZwyzZb23cEiRsq9kwUf3"
     & "6ET4KhjdG8Ss45i0OE"",""y"":""0ErI5PwjId8ophqZG7raSNIAZSk8-qS36fi3oWsZ1xY""}"
     & ",{""kty"":""OKP"",""kid"":""ed1"",""crv"":""Ed25519"",""x"":""f2KQblJJ5t6SN-pbfsme6rI"
     & "0VZSrPr6J1DYQL7qEbf8""},{""kty"":""RSA"",""kid"":""enc1"",""use"":""enc"",""n"":""n9CL"
     & "o34XeXorf7C7sHNv1SrjPG8lIjk6zPysbRrAyL54wyzEyVu6W5bYrZMtQ0gNFYctjQcqCB"
     & "NWHaDa2X47jKrw0czottVW5U5FUO9k5jl6TUgD8R0lRKoaT6q-Lz8FbDBsuh1aqwWGxNcg"
     & "LofYAtcwtM6HYkWoGE1Thfsr7-zIALVrUwz7yHoHdQGWkIp0Bdsc-qRw-b98gacIsFNROh"
     & "J635sABBlx1dYXBc0drwIwFPguwk_U09CyuuC5CbPnzGQtiXL8a4gpRGpSS7EvgLgs8rAi"
     & "xFGYOz-gOKD5smmwZCK-AvYLRQvt1Wc7l1YYyrK2moUTpGjjwlT4apWqWQ"",""e"":""AQAB"""
     & "},{""kty"":""RSA"",""kid"":""small"",""n"":""okD8leaxeRNaUIifaNglHi-JxYgo5lQhS0I5"
     & "qtQnkAXuSxRgxEnwaG_yxDemwRAgCjKuuib5vKR0n5Y3BmfpkzztkXqkuBD7D8eWymxaWv"
     & "A8-Sa6ho9_2KlrIFrNTngYJ9CkiXuaYfQyNhtpRMhypQYk9gaZPSqlu1V3RF9gDDU"",""e"""
     & ":""AQAB""},{""kty"":""oct"",""kid"":""secret"",""k"":""c2VjcmV0""}]}";

   Rs256_Token : constant String :=
     "eyJhbGciOiJSUzI1NiIsImtpZCI6InJzYTEiLCJ0eXAiOiJKV1QifQ.eyJzdWIiOiI0MiI"
     & "sImlzcyI6Imh0dHBzOi8vaXNzdWVyLnRlc3QiLCJhdWQiOiJjbGllbnQiLCJleHAiOjQxM"
     & "DI0NDQ4MDAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJuMSJ9.DS0N4OZ-RIwi5jnwS7"
     & "Tlvic0GNdARxT0-WBn5iVHndtQmjxg6JyAgsV0ch1avfYpnYPeHKcwmhSdFiQIzBDuWx-v"
     & "tqlvB8zb3EB4K8hukHWgSjQ61W_eMMRTcUXukF0j6yDMg2ZBKFXUPGi8RmB0oPE8igLf8M"
     & "RCJCf-iQuB9wDOuq4TqJZ0_oGAkl16y9PU9rrNTb2JMXSHGnAKFGm9o8-UllJk8si9gWBN"
     & "RQyP6bGzAydKwl_CjzGQFnui1ZZifTdLYwaJYloiuidOKgBW-5zh77ahszWYJ0WiJ-INQ9"
     & "3mj8Q2w83I6AYbPA41d7hJ0D3L8cPXjEsv6JDqyTohyg";

   Es256_Token : constant String :=
     "eyJhbGciOiJFUzI1NiIsImtpZCI6ImVjMSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsI"
     & "mlzcyI6Imh0dHBzOi8vaXNzdWVyLnRlc3QiLCJhdWQiOiJjbGllbnQiLCJleHAiOjQxMDI"
     & "0NDQ4MDAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJuMSJ9.BP39rroxIvxABnXRO0-R"
     & "0AQDg5dQJeHXISz98pxfGL8hXV_8WMLCb8RC4hqD0_NJ-x24fUQWocKhSDY6435srw";

   Eddsa_Token : constant String :=
     "eyJhbGciOiJFZERTQSIsImtpZCI6ImVkMSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsI"
     & "mlzcyI6Imh0dHBzOi8vaXNzdWVyLnRlc3QiLCJhdWQiOiJjbGllbnQiLCJleHAiOjQxMDI"
     & "0NDQ4MDAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJuMSJ9.l1TOi8vKxmuKn6dTK3Db"
     & "cASYwQ4YjqymI118t92J51rHqqH0xGbC34JiLJ7R_w3Y12R68HOoXv9_PQ-acG6jDQ";

   Small_Rsa_Token : constant String :=
     "eyJhbGciOiJSUzI1NiIsImtpZCI6InNtYWxsIiwidHlwIjoiSldUIn0.eyJzdWIiOiI0Mi"
     & "IsImlzcyI6Imh0dHBzOi8vaXNzdWVyLnRlc3QiLCJhdWQiOiJjbGllbnQiLCJleHAiOjQx"
     & "MDI0NDQ4MDAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJuMSJ9.oGrTcdOaMoVoZbYum"
     & "FdhsWS8-sR21FYhE0ZZFHmDP_1XsAnqG8P-MTjNffLChhg2x-vtR2HTIi8TEaTvG3845QW"
     & "2Q0_IBQM_bnj0DnRs4I1nwhXuBDvLYKeXGh8v3lZ9ND9d0lO5jINRTbByARVNVqtY5JY8W"
     & "FZg9bUs_m7wAC8";

   Wrong_Kid_Token : constant String :=
     "eyJhbGciOiJSUzI1NiIsImtpZCI6ImVjMSIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsI"
     & "mlzcyI6Imh0dHBzOi8vaXNzdWVyLnRlc3QiLCJhdWQiOiJjbGllbnQiLCJleHAiOjQxMDI"
     & "0NDQ4MDAsImlhdCI6MTcwMDAwMDAwMCwibm9uY2UiOiJuMSJ9.mDHmWtwbyfiNuPdGQPJ9"
     & "ags4m_lWh_xH_HY28-tugpwR_8JHJ3J7cIVHGX-DKlkrXxE-XEi7PyL8y3wWbob4-c1fb5"
     & "RmhOn4cAIbGZkFo_2tEAVJzHfB2Z1Et-wBWbjlUFdBeDpDzr1cy_WBo2oPxVdKWdpgyMS_"
     & "yPvu5mprab5rs3Og3oO4pEboM4YiiybrNipqbQ_IwbDzUdNUdj5G75uuyrUa0xZW12JWBs"
     & "VSx6gokwOZxaV0Gmnh2gMYHdkTNywq9W1ojB1Lwe9Ck2Nmb-pfRc1v70Gy0ua1QJEs1w9i"
     & "EDuMFot1094eX2rnrNSQTaZlDtyz_Yy5D4AlJBDONA";

   Rsa_Private_Pem : constant String :=
     "-----BEGIN PRIVATE KEY-----" & ASCII.LF
     & "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCf0Iujfhd5eit/" & ASCII.LF
     & "sLuwc2/VKuM8byUiOTrM/KxtGsDIvnjDLMTJW7pbltitky1DSA0Vhy2NByoIE1Yd" & ASCII.LF
     & "oNrZfjuMqvDRzOi21VblTkVQ72TmOXpNSAPxHSVEqhpPqr4vPwVsMGy6HVqrBYbE" & ASCII.LF
     & "1yAuh9gC1zC0zodiRagYTVOF+yvv7MgAtWtTDPvIegd1AZaQinQF2xz6pHD5v3yB" & ASCII.LF
     & "pwiwU1E6EnrfmwAEGXHV1hcFzR2vAjAU+C7CT9TT0LK64LkJs+fMZC2JcvxriClE" & ASCII.LF
     & "alJLsS+AuCzysCLEUZg7P6A4oPmyabBkIr4C9gtFC+3VZzuXVhjKsraahROkaOPC" & ASCII.LF
     & "VPhqlapZAgMBAAECggEABkBBPKl0MBrJ+Zzh/oPJZPMK6oR7apmxSy7P7MA+OFaQ" & ASCII.LF
     & "69YZXWSShxNrpsBqEGa7Ukipt17cyJjpsPond+3df5dObkUKTjUiiLtqxStpTNhZ" & ASCII.LF
     & "3bd6e1N1RM4K05ZoCXo401OX5nYQTj5cAuDaP/pYGzurtUrFwLTc9L8ONwr3xpLd" & ASCII.LF
     & "IyiFKcwDkZPeDzJcfy/02RdF0Sy7ybJ0Nwvi3TPTamcQjq+ZF0ZGKB4DhTsiSeLK" & ASCII.LF
     & "8m8ovEJbYywmU+95LLeFz/IczA40p2h89JgADL9OwxiLBGv+IJn3QieJKmZuJpI1" & ASCII.LF
     & "H32CDHN45HfVcVw308BoD0VrgCdTZXL2J7M5+jan4QKBgQDVKPZBII0dVHxh/wnQ" & ASCII.LF
     & "z2WdedtCT6C7Ov27ZnGKhCmxR5uG17c7vbWPJYQGFwkRrc4ViEd6uuHgYcUVHKNS" & ASCII.LF
     & "WF/n7wjcmN7Kc/WANxL8kQ1e8kZH/iu+VR90sQ7mM1xeCHr6JvRS+IdXc2O/EHvR" & ASCII.LF
     & "RzB95CkWaA1qETLfsmc5979LiQKBgQC/7vmYqwmdf06dwZ/0I0A/eiLd3FXUPqUz" & ASCII.LF
     & "gwsohyfOnKw8c2W5Uanj/3TMNVCGLEmzLna2s0Y1vR3Q/bUSc+gy4hD3U24VXEyb" & ASCII.LF
     & "8dt1+lo6hk7/DIA1q7KMUj5xaEBVbI/YFRahGyQxSFFQ3NaXTDhuoi5NxliEAYts" & ASCII.LF
     & "v31Tg5OkUQKBgQCM8ByCS0eCkQ38rWiMC9UgHiX+3i9kHEkP01hXQbNfZ/1JVu/s" & ASCII.LF
     & "LC8TiraUYD661bRhQE4is9YNShfJMbo7A/vFmqK9WMZWDf3Q3JlNLYstr/sQNtot" & ASCII.LF
     & "apL10OwNAQCdm/XT2FXLVlAGXmEhP4DeirdhRa51Bi94Zg7BIXBnP4vYIQKBgGEw" & ASCII.LF
     & "f89g/LN2HbcgrwCPQR9jl3hE9GlPd5QIDYRuPCgRid3qiV44DhFX8Crf7HCkyIUl" & ASCII.LF
     & "SBPn3+uiYhDMB/7aFoB9nR3Ab4P9gwWMiRbKuRndnO7lw55p3TXVB62hnsIjAQvo" & ASCII.LF
     & "UdcuyTrzZcnOqhNfE0xib5QOlg/yQEnHBY1emUqhAoGAY+Fk4Rc1UTVeIPo9Fy/j" & ASCII.LF
     & "9ZrXrGn4lXKebNhtsj5N62U8NquW1kcpVfIQMDdTU7iFOaOrN5WTLCoqA19zdLmd" & ASCII.LF
     & "2jittxphoOIdGRprEHXUkp73RrDhv2stAL+3wVpknyiDE06Zp8uhT3yqJOemIcrL" & ASCII.LF
     & "jDdyQPqMAeNBJPFnxCeqPbY=" & ASCII.LF
     & "-----END PRIVATE KEY-----" & ASCII.LF
     & "";

   Ec_Private_Pem : constant String :=
     "-----BEGIN PRIVATE KEY-----" & ASCII.LF
     & "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg3KWLljGduuJXKdbY" & ASCII.LF
     & "K185oiDT9mPbqC0Cs37NQdg760OhRANCAASCvPTxnDLNlvbdwSJGyr2TBR/foRPg" & ASCII.LF
     & "qGN0bxKzjmLQ4dBKyOT8IyHfKKYamRu62kjSAGUpPPqkt+n4t6FrGdcW" & ASCII.LF
     & "-----END PRIVATE KEY-----" & ASCII.LF
     & "";

   Ed25519_Private_Pem : constant String :=
     "-----BEGIN PRIVATE KEY-----" & ASCII.LF
     & "MC4CAQAwBQYDK2VwBCIEIM74j0dn2DlEmnGEUsFrAeMOPjsesLX8HFM16R8lK+eq" & ASCII.LF
     & "-----END PRIVATE KEY-----" & ASCII.LF
     & "";

   Rsa_Public_Pem : constant String :=
     "-----BEGIN PUBLIC KEY-----" & ASCII.LF
     & "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAn9CLo34XeXorf7C7sHNv" & ASCII.LF
     & "1SrjPG8lIjk6zPysbRrAyL54wyzEyVu6W5bYrZMtQ0gNFYctjQcqCBNWHaDa2X47" & ASCII.LF
     & "jKrw0czottVW5U5FUO9k5jl6TUgD8R0lRKoaT6q+Lz8FbDBsuh1aqwWGxNcgLofY" & ASCII.LF
     & "AtcwtM6HYkWoGE1Thfsr7+zIALVrUwz7yHoHdQGWkIp0Bdsc+qRw+b98gacIsFNR" & ASCII.LF
     & "OhJ635sABBlx1dYXBc0drwIwFPguwk/U09CyuuC5CbPnzGQtiXL8a4gpRGpSS7Ev" & ASCII.LF
     & "gLgs8rAixFGYOz+gOKD5smmwZCK+AvYLRQvt1Wc7l1YYyrK2moUTpGjjwlT4apWq" & ASCII.LF
     & "WQIDAQAB" & ASCII.LF
     & "-----END PUBLIC KEY-----" & ASCII.LF
     & "";

end Jwt_Vectors;
