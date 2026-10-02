package com.ahbu.evotomasyon.ev_otomasyon

/**
 * IPv4 alt ağı (CIDR gösterimi, ör. `192.168.4.0/24`): ayrıştırma + bir adresin kapsanması.
 *
 * SAF Kotlin: hiçbir Android sınıfı kullanmaz, bu yüzden JVM birim testiyle doğrulanır
 * (`src/test/.../Ipv4SubnetTest.kt`). [BoardNetworkCore] "bu Wi-Fi ağı panonun kurulum ağı mı?"
 * sorusunu bununla yanıtlar: ağın bağlantı adresleri (LinkProperties.linkAddresses) içindeki IPv4
 * adreslerinden biri alt ağa düşüyorsa evet.
 *
 * Kurallar (bilerek KATI; bozuk girdi sessizce yanlış alt ağa dönüşmesin diye):
 *  - Biçim yalnız `a.b.c.d/p`: tam dört onluk sekizli + tek `/` + önek. Boşluk, `+`/`-`, onaltılık,
 *    ASCII dışı rakam, eksik/fazla parça, IPv6 (`::`, `:`) → `null`.
 *  - Sekizli 0..255, önek 0..32; ikisinde de gereksiz baştaki sıfır (`04`, `024`) reddedilir
 *    (bazı ayrıştırıcılar bunu sekizlik sayar; belirsizliği baştan kapatırız).
 *  - Konak bitleri ÖNEKE GÖRE SIFIRLANIR (`192.168.4.77/24` == `192.168.4.0/24`); Android'in
 *    `IpPrefix` kurucusu da adresi sessizce kırpar, aynı kuralı izleriz.
 *  - [contains] yalnız 4 baytlık adresi kabul eder; başka uzunluk (ör. IPv6'nın 16 baytı) `/0`
 *    için bile `false` döner ("IPv6 reddedilir").
 */
internal class Ipv4Subnet private constructor(
    /** Ağ adresi (konak bitleri sıfır), 32 bitlik bit deseni olarak; işareti anlamsızdır. */
    private val networkBits: Int,
    /** Önek uzunluğu, 0..32. */
    val prefixLength: Int,
) {
    private val maskBits: Int = maskOf(prefixLength)

    /** [address] (ağ bayt sırasıyla 4 bayt; `Inet4Address.address`) bu alt ağda mı? */
    fun contains(address: ByteArray): Boolean {
        if (address.size != ADDRESS_BYTES) return false
        return (bitsOf(address) and maskBits) == networkBits
    }

    /** [addresses] içinden en az biri bu alt ağda mı? Boş koleksiyon → `false`. */
    fun containsAny(addresses: Iterable<ByteArray>): Boolean = addresses.any { contains(it) }

    override fun equals(other: Any?): Boolean =
        other is Ipv4Subnet && other.networkBits == networkBits && other.prefixLength == prefixLength

    override fun hashCode(): Int = 31 * networkBits + prefixLength

    /** Kanonik biçim: `192.168.4.0/24`. */
    override fun toString(): String =
        "${(networkBits ushr 24) and 0xFF}.${(networkBits ushr 16) and 0xFF}." +
            "${(networkBits ushr 8) and 0xFF}.${networkBits and 0xFF}/$prefixLength"

    companion object {
        private const val ADDRESS_BYTES = 4
        private const val MAX_PREFIX = 32
        private const val MAX_OCTET = 255

        /** `a.b.c.d/p` metnini ayrıştırır; geçersizse `null` (istisna FIRLATMAZ). */
        fun parse(text: String): Ipv4Subnet? {
            val slash = text.indexOf('/')
            if (slash < 0 || slash != text.lastIndexOf('/')) return null

            val prefix = parseDecimal(text.substring(slash + 1), maxDigits = 2, maxValue = MAX_PREFIX)
                ?: return null

            // split('.') boş parçaları korur: "1.2.3." -> ["1","2","3",""] -> parseDecimal reddeder.
            val octets = text.substring(0, slash).split('.')
            if (octets.size != ADDRESS_BYTES) return null

            var bits = 0
            for (octet in octets) {
                val value = parseDecimal(octet, maxDigits = 3, maxValue = MAX_OCTET) ?: return null
                bits = (bits shl 8) or value
            }
            return Ipv4Subnet(bits and maskOf(prefix), prefix)
        }

        /**
         * Yalnız ASCII '0'..'9'. `String.toIntOrNull()` KULLANILMAZ: baştaki `+` ve ASCII dışı
         * (ör. tam genişlikli/Arapça-Hint) rakamları da kabul eder.
         */
        private fun parseDecimal(s: String, maxDigits: Int, maxValue: Int): Int? {
            if (s.isEmpty() || s.length > maxDigits) return null
            if (s.length > 1 && s[0] == '0') return null
            var value = 0
            for (c in s) {
                if (c !in '0'..'9') return null
                value = value * 10 + (c - '0')
            }
            return if (value > maxValue) null else value
        }

        /** Önek 0..32 için maske. Kotlin'de `-1 shl 32` == `-1 shl 0` olduğundan 0 ayrıca ele alınır. */
        private fun maskOf(prefix: Int): Int = if (prefix == 0) 0 else -1 shl (MAX_PREFIX - prefix)

        private fun bitsOf(address: ByteArray): Int =
            ((address[0].toInt() and 0xFF) shl 24) or
                ((address[1].toInt() and 0xFF) shl 16) or
                ((address[2].toInt() and 0xFF) shl 8) or
                (address[3].toInt() and 0xFF)
    }
}
