package com.buildtoapp.ir_net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationTextTest {
    private val frankfurt = IpInfo("DE", "Germany", "Hesse", "Frankfurt am Main", "Example GmbH", "45.76.91.5", 50.1, 8.6)

    @Test
    fun `without the VPN it reads as before`() {
        val t = NotificationText.of(IpState.Located(frankfurt), null)
        assertEquals("🇩🇪 Germany", t.title)
        assertEquals("IP: 45.76.91.5 | Frankfurt am Main", t.text)
        assertEquals("IP: 45.76.91.5\nCity: Frankfurt am Main\nISP: Example GmbH", t.bigText)
    }

    @Test
    fun `with IRNet's VPN connected it says so and names the config`() {
        val t = NotificationText.of(IpState.Located(frankfurt), VpnInfo("🇩🇪 Germany 1"))
        assertEquals("VPN on · IP: 45.76.91.5 | Frankfurt am Main", t.text)
        assertTrue(t.bigText, t.bigText.startsWith("IRNet VPN: 🇩🇪 Germany 1\nIP: 45.76.91.5"))

        val unnamed = NotificationText.of(IpState.Starting, VpnInfo(null))
        assertEquals("IRNet VPN connected", unnamed.title)
        assertEquals("VPN on · ${NotificationText.CHECKING}", unnamed.text)
        assertTrue(unnamed.bigText.startsWith("IRNet VPN: connected"))
    }

    @Test
    fun `a pending lookup keeps the last place and says it's checking`() {
        val t = NotificationText.of(IpState.Located(frankfurt, checking = true), null)
        assertEquals("🇩🇪 Germany", t.title)
        assertEquals(NotificationText.CHECKING, t.text)
        assertTrue(t.bigText.endsWith(NotificationText.CHECKING))
    }

    @Test
    fun `offline and failed lookups`() {
        assertEquals("No internet connection", NotificationText.of(IpState.Offline, null).title)
        val failed = NotificationText.of(IpState.Unavailable(frankfurt), VpnInfo("X"))
        assertEquals("VPN on · Could not resolve IP location", failed.text)
    }
}
