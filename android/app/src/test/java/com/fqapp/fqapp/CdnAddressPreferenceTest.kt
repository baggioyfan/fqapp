package com.example.shortplay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress

/**
 * Android 的媒体取流走 okhttp（[HttpRangeClient]），与 Rust 桌面侧的
 * `ipv4_first`（rust/src/desktop_media.rs）是两套实现，同一条策略两边都要有：
 * 媒体 CDN 的 AAAA 在家宽上常被黑洞，必须先把 A 记录试完。
 */
class CdnAddressPreferenceTest {
    private fun v4(last: Int): InetAddress = InetAddress.getByAddress(byteArrayOf(10, 0, 0, last.toByte()))

    private fun v6(last: Int): InetAddress =
        InetAddress.getByAddress(ByteArray(15) + last.toByte())

    @Test
    fun ipv4AddressesComeFirstAndKeepTheirOrder() {
        val a = v6(1)
        val b = v4(2)
        val c = v6(3)
        val d = v4(4)

        assertEquals(listOf(b, d, a, c), preferIpv4Addresses(listOf(a, b, c, d)))
    }

    @Test
    fun ipv6OnlyHostsKeepTheirResolutionOrder() {
        val a = v6(1)
        val b = v6(2)

        assertEquals(listOf(a, b), preferIpv4Addresses(listOf(a, b)))
    }

    @Test
    fun noRecordStaysEmpty() {
        assertTrue(preferIpv4Addresses(emptyList()).isEmpty())
    }
}
