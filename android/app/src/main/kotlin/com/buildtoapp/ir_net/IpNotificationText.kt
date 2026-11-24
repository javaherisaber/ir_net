package com.buildtoapp.ir_net

/** What the ongoing IP location notification shows. */
sealed class IpState {
    /** Nothing looked up yet. */
    object Starting : IpState()

    /** [checking]: the network changed and a fresh lookup is under way. */
    data class Located(val info: IpInfo, val checking: Boolean = false) : IpState()
    data class Unavailable(val last: IpInfo?) : IpState()
    object Offline : IpState()
}

/** IRNet's own VPN, while it's connected; [name] is the config's, when the app has said. */
data class VpnInfo(val name: String?)

/** The notification's words, kept apart from Android so they can be unit-tested. */
object NotificationText {
    const val CHECKING = "Checking IP location…"

    data class Texts(val title: String, val text: String, val bigText: String)

    fun of(state: IpState, vpn: VpnInfo?): Texts {
        val vpnLine = vpn?.let { "IRNet VPN: ${it.name?.takeIf { n -> n.isNotBlank() } ?: "connected"}" }
        fun short(text: String) = if (vpn != null) "VPN on · $text" else text
        fun long(vararg lines: String?) = listOfNotNull(vpnLine, *lines).joinToString("\n")
        return when (state) {
            is IpState.Located -> {
                val i = state.info
                Texts(
                    title = "${i.flag} ${i.country}".trim(),
                    text = short(if (state.checking) CHECKING else "IP: ${i.ip} | ${i.city}"),
                    bigText = long("IP: ${i.ip}", "City: ${i.city}", "ISP: ${i.isp}", if (state.checking) CHECKING else null),
                )
            }
            is IpState.Unavailable -> Texts(
                title = "⚠️ IP location unavailable",
                text = short("Could not resolve IP location"),
                bigText = long("Could not resolve IP location.", "IRNet tries again when the network changes and every minute."),
            )
            IpState.Offline -> Texts(
                title = "No internet connection",
                text = "IRNet updates this when you're back online",
                bigText = long("IRNet updates this when you're back online"),
            )
            IpState.Starting -> Texts(
                title = if (vpn != null) "IRNet VPN connected" else "IRNet",
                text = short(CHECKING),
                bigText = long(CHECKING),
            )
        }
    }
}
