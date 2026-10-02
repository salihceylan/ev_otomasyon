package com.ahbu.evotomasyon.ev_otomasyon

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ipv4Subnet: SAF mantık (Android yok) -> JVM birim testi. */
class Ipv4SubnetTest {

    /** Taşma/işaret hatalarını yakalamak için 0..255 girdi alır ve baytı doğru (işaretli) kurar. */
    private fun ip(a: Int, b: Int, c: Int, d: Int): ByteArray =
        byteArrayOf(a.toByte(), b.toByte(), c.toByte(), d.toByte())

    private fun subnet(text: String): Ipv4Subnet {
        val parsed = Ipv4Subnet.parse(text)
        assertNotNull("ayrıştırılmalıydı: $text", parsed)
        return parsed!!
    }

    // ---- ayrıştırma: geçerli ------------------------------------------------------------------

    @Test
    fun parse_validSlash24_roundTripsCanonically() {
        val s = subnet("192.168.4.0/24")
        assertEquals(24, s.prefixLength)
        assertEquals("192.168.4.0/24", s.toString())
    }

    @Test
    fun parse_masksHostBitsLikeAndroidIpPrefix() {
        // 192.168.4.77/24 == 192.168.4.0/24 (konak bitleri sessizce sıfırlanır).
        assertEquals(subnet("192.168.4.0/24"), subnet("192.168.4.77/24"))
        assertEquals("192.168.4.0/24", subnet("192.168.4.77/24").toString())
        assertEquals(subnet("192.168.4.0/24").hashCode(), subnet("192.168.4.1/24").hashCode())
        // /0 her şeyi sıfırlar.
        assertEquals("0.0.0.0/0", subnet("10.20.30.40/0").toString())
        // /32 hiçbir bit sıfırlamaz.
        assertEquals("10.20.30.40/32", subnet("10.20.30.40/32").toString())
        // /31, /30 sınırları
        assertEquals("10.0.0.2/31", subnet("10.0.0.3/31").toString())
        assertEquals("10.0.0.4/30", subnet("10.0.0.7/30").toString())
    }

    @Test
    fun equals_distinguishesNetworkAndPrefix() {
        assertNotEquals(subnet("192.168.4.0/24"), subnet("192.168.5.0/24"))
        assertNotEquals(subnet("192.168.4.0/24"), subnet("192.168.4.0/25"))
        assertNotEquals(subnet("192.168.4.0/24") as Any, "192.168.4.0/24" as Any)
    }

    // ---- kapsama: /24 kenarları ---------------------------------------------------------------

    @Test
    fun contains_slash24_edges() {
        val s = subnet("192.168.4.0/24")
        assertTrue(s.contains(ip(192, 168, 4, 0)))
        assertTrue(s.contains(ip(192, 168, 4, 1)))
        assertTrue(s.contains(ip(192, 168, 4, 2)))
        assertTrue(s.contains(ip(192, 168, 4, 128))) // bayt işaretli negatif (-128)
        assertTrue(s.contains(ip(192, 168, 4, 255))) // bayt -1
        assertFalse(s.contains(ip(192, 168, 3, 255)))
        assertFalse(s.contains(ip(192, 168, 5, 0)))
        assertFalse(s.contains(ip(192, 169, 4, 1)))
        assertFalse(s.contains(ip(193, 168, 4, 1)))
        assertFalse(s.contains(ip(10, 168, 4, 1)))
    }

    @Test
    fun contains_slash25_splitsLastOctet() {
        val low = subnet("192.168.4.0/25")
        assertTrue(low.contains(ip(192, 168, 4, 0)))
        assertTrue(low.contains(ip(192, 168, 4, 127)))
        assertFalse(low.contains(ip(192, 168, 4, 128)))
        val high = subnet("192.168.4.128/25")
        assertFalse(high.contains(ip(192, 168, 4, 127)))
        assertTrue(high.contains(ip(192, 168, 4, 128)))
        assertTrue(high.contains(ip(192, 168, 4, 255)))
    }

    // ---- kapsama: /32, /31, /0 ------------------------------------------------------------------

    @Test
    fun contains_slash32_onlyExactAddress() {
        val s = subnet("192.168.4.1/32")
        assertTrue(s.contains(ip(192, 168, 4, 1)))
        assertFalse(s.contains(ip(192, 168, 4, 0)))
        assertFalse(s.contains(ip(192, 168, 4, 2)))
        assertFalse(s.contains(ip(192, 168, 5, 1)))
        // En yüksek adres (tüm bitler 1): maske hatası (shl 32) burada yakalanır.
        val top = subnet("255.255.255.255/32")
        assertTrue(top.contains(ip(255, 255, 255, 255)))
        assertFalse(top.contains(ip(255, 255, 255, 254)))
        val zero = subnet("0.0.0.0/32")
        assertTrue(zero.contains(ip(0, 0, 0, 0)))
        assertFalse(zero.contains(ip(0, 0, 0, 1)))
    }

    @Test
    fun contains_slash31_twoAddresses() {
        val s = subnet("10.0.0.2/31")
        assertFalse(s.contains(ip(10, 0, 0, 1)))
        assertTrue(s.contains(ip(10, 0, 0, 2)))
        assertTrue(s.contains(ip(10, 0, 0, 3)))
        assertFalse(s.contains(ip(10, 0, 0, 4)))
    }

    @Test
    fun contains_slash0_matchesEveryIpv4Address() {
        val s = subnet("0.0.0.0/0")
        assertTrue(s.contains(ip(0, 0, 0, 0)))
        assertTrue(s.contains(ip(10, 1, 2, 3)))
        assertTrue(s.contains(ip(127, 0, 0, 1)))
        assertTrue(s.contains(ip(128, 0, 0, 1)))
        assertTrue(s.contains(ip(255, 255, 255, 255)))
    }

    @Test
    fun contains_slash1_highBitBoundary() {
        val upper = subnet("128.0.0.0/1")
        assertFalse(upper.contains(ip(127, 255, 255, 255)))
        assertTrue(upper.contains(ip(128, 0, 0, 0)))
        assertTrue(upper.contains(ip(255, 255, 255, 255)))
        val lower = subnet("0.0.0.0/1")
        assertTrue(lower.contains(ip(0, 0, 0, 0)))
        assertTrue(lower.contains(ip(127, 255, 255, 255)))
        assertFalse(lower.contains(ip(128, 0, 0, 0)))
    }

    @Test
    fun contains_otherPrefixLengths() {
        val s8 = subnet("10.0.0.0/8")
        assertTrue(s8.contains(ip(10, 255, 255, 255)))
        assertFalse(s8.contains(ip(11, 0, 0, 0)))
        assertFalse(s8.contains(ip(9, 255, 255, 255)))
        val s16 = subnet("172.16.0.0/16")
        assertTrue(s16.contains(ip(172, 16, 255, 255)))
        assertFalse(s16.contains(ip(172, 17, 0, 0)))
        // /30 -> 4 adres
        val s30 = subnet("192.168.4.4/30")
        assertFalse(s30.contains(ip(192, 168, 4, 3)))
        assertTrue(s30.contains(ip(192, 168, 4, 4)))
        assertTrue(s30.contains(ip(192, 168, 4, 7)))
        assertFalse(s30.contains(ip(192, 168, 4, 8)))
        // /23 iki /24'ü kapsar
        val s23 = subnet("192.168.4.0/23")
        assertTrue(s23.contains(ip(192, 168, 4, 9)))
        assertTrue(s23.contains(ip(192, 168, 5, 250)))
        assertFalse(s23.contains(ip(192, 168, 6, 0)))
        assertFalse(s23.contains(ip(192, 168, 3, 255)))
    }

    // ---- kapsama: IPv4 dışı / bozuk uzunluk -----------------------------------------------------

    @Test
    fun contains_rejectsNonFourByteAddresses() {
        val everything = subnet("0.0.0.0/0")
        assertFalse(everything.contains(ByteArray(0)))
        assertFalse(everything.contains(ByteArray(3)))
        assertFalse(everything.contains(ByteArray(5)))
        // IPv6 (16 bayt) /0 için bile reddedilir.
        assertFalse(everything.contains(ByteArray(16)))
        // IPv4-eşlenmiş IPv6 (::ffff:192.168.4.1) 16 bayt olarak verilirse de reddedilir.
        val mapped = ByteArray(16)
        mapped[10] = 0xFF.toByte()
        mapped[11] = 0xFF.toByte()
        mapped[12] = 192.toByte()
        mapped[13] = 168.toByte()
        mapped[14] = 4
        mapped[15] = 1
        assertFalse(subnet("192.168.4.0/24").contains(mapped))
    }

    @Test
    fun containsAny_findsAMatchAmongSeveralAddresses() {
        val s = subnet("192.168.4.0/24")
        assertFalse(s.containsAny(emptyList()))
        assertFalse(s.containsAny(listOf(ip(10, 0, 0, 5), ip(192, 168, 1, 20))))
        assertTrue(s.containsAny(listOf(ip(10, 0, 0, 5), ip(192, 168, 4, 20))))
        // Boş (bozuk) adresler eşleşmeyi bozmaz, yalnız atlanır.
        assertTrue(s.containsAny(listOf(ByteArray(16), ip(192, 168, 4, 2))))
    }

    // ---- ayrıştırma: geçersiz -------------------------------------------------------------------

    @Test
    fun parse_rejectsMalformedText() {
        val bad = listOf(
            "", "/", "/24", "192.168.4.0", "192.168.4.0/", "192.168.4.0//24", "192.168.4.0/24/",
            "192.168.4.0/33", "192.168.4.0/99", "192.168.4.0/100", "192.168.4.0/-1", "192.168.4.0/+24",
            "192.168.4.0/2 4", "192.168.4.0/ 24", "192.168.4.0/24 ", " 192.168.4.0/24",
            "192.168.4/24", "192.168.4.0.1/24", "192.168..0/24", "192.168.4./24", ".168.4.0/24",
            "256.1.1.1/24", "1.2.3.256/24", "1.2.3.-4/24", "1.2.3.+4/24", "1.2.3.4a/24", "a.b.c.d/24",
            "0x7f.0.0.1/8", "1,2,3,4/24", "192-168-4-0/24", "192.168.4.0\\24",
            // gereksiz baştaki sıfır: belirsizlik (sekizlik?) baştan reddedilir
            "192.168.04.0/24", "192.168.4.00/24", "192.168.004.0/24", "192.168.4.0/024", "192.168.4.0/08",
            // çok uzun sekizli / önek
            "1920.168.4.0/24", "192.168.4.0/240",
            // ASCII dışı rakamlar (tam genişlikli, Arapça-Hint): toIntOrNull() bunları kabul ederdi
            "１９２.１６８.４.０/２４", "192.168.4.0/٢٤",
            // IPv6
            "::1/128", "fe80::1/64", "2001:db8::/32", "::ffff:192.168.4.1/24", "[::1]/128",
            // boşluk/sekme/satır sonu
            "192.168.4.0/24\n", "192.168.4.0/24\t", "\t192.168.4.0/24",
        )
        for (text in bad) {
            assertNull("reddedilmeliydi: '$text'", Ipv4Subnet.parse(text))
        }
    }

    @Test
    fun parse_acceptsEveryValidPrefixLengthFrom0To32() {
        for (prefix in 0..32) {
            val s = Ipv4Subnet.parse("192.168.4.1/$prefix")
            assertNotNull("önek $prefix kabul edilmeliydi", s)
            assertEquals(prefix, s!!.prefixLength)
            // Adresin kendisi (konak bitleri maskelense bile) kendi alt ağında olmalıdır.
            assertTrue("önek $prefix: adres kendi alt ağında", s.contains(ip(192, 168, 4, 1)))
        }
        assertNull(Ipv4Subnet.parse("192.168.4.1/33"))
    }

    @Test
    fun parse_acceptsBoundaryOctets() {
        assertNotNull(Ipv4Subnet.parse("0.0.0.0/0"))
        assertNotNull(Ipv4Subnet.parse("255.255.255.255/32"))
        assertNotNull(Ipv4Subnet.parse("0.0.0.0/32"))
        assertNotNull(Ipv4Subnet.parse("1.2.3.4/32"))
        assertNotNull(Ipv4Subnet.parse("100.64.0.0/10")) // CGNAT
        assertNull(Ipv4Subnet.parse("0.0.0.256/32"))
    }
}
