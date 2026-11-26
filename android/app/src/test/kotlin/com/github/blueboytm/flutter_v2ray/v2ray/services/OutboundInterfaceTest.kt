package com.github.blueboytm.flutter_v2ray.v2ray.services

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/** IRNet's Xray TUN mode patch to flutter_v2ray (third_party/flutter_v2ray/IRNET.md). */
class OutboundInterfaceTest {
    private val config = """
        {"inbounds":[{"tag":"tun","protocol":"tun","settings":{"name":"xray0"}}],
         "outbounds":[
          {"tag":"proxy","protocol":"vless","streamSettings":{"security":"tls","sockopt":{"domainStrategy":"UseIP","interface":"irnet-unbound"}}},
          {"tag":"wg","protocol":"wireguard"},
          {"tag":"block","protocol":"blackhole"}
        ]}
    """.trimIndent()

    private fun sockopt(json: String, i: Int) =
        JSONObject(json).getJSONArray("outbounds").getJSONObject(i).getJSONObject("streamSettings").getJSONObject("sockopt")

    @Test
    fun bindsEveryOutboundToTheCurrentNetworksInterface() {
        val out = V2rayVPNService.withOutboundInterface(config, "wlan0")
        assertEquals("wlan0", sockopt(out, 0).getString("interface"))
        assertEquals("keeps what was there", "UseIP", sockopt(out, 0).getString("domainStrategy"))
        assertEquals("tls", JSONObject(out).getJSONArray("outbounds").getJSONObject(0)
            .getJSONObject("streamSettings").getString("security"))
        assertEquals("wlan0", sockopt(out, 1).getString("interface"))
        assertFalse("blackhole connects nowhere",
            JSONObject(out).getJSONArray("outbounds").getJSONObject(2).has("streamSettings"))
        // The network moved to mobile data.
        assertEquals("rmnet_data2", sockopt(V2rayVPNService.withOutboundInterface(out, "rmnet_data2"), 0).getString("interface"))
    }

    @Test
    fun withoutANetworkXrayFailsClosedInsteadOfLooping() {
        assertEquals(V2rayVPNService.NO_INTERFACE, sockopt(V2rayVPNService.withOutboundInterface(config, null), 1).getString("interface"))
    }
}
