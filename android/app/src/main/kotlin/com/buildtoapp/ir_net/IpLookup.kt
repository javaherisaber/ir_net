package com.buildtoapp.ir_net

import org.json.JSONObject
import java.io.IOException
import java.net.Authenticator
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.PasswordAuthentication
import java.net.ProtocolException
import java.net.Proxy
import java.net.URL
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/**
 * The local HTTP proxy IRNet's own requests go through while its VPN is
 * connected ("user:pass@127.0.0.1:10809"). Android keeps IRNet itself out
 * of the tunnel, so without it a lookup would see the real address.
 */
data class LookupProxy(val host: String, val port: Int, val user: String?, val pass: String?) {
    @OptIn(ExperimentalEncodingApi::class)
    val basicAuth: String?
        get() = user?.let { "Basic " + Base64.encode("$it:${pass ?: ""}".toByteArray()) }

    companion object {
        fun parse(spec: String?): LookupProxy? {
            val s = spec?.trim().orEmpty()
            if (s.isEmpty()) return null
            val at = s.lastIndexOf('@')
            val credentials = if (at >= 0) s.substring(0, at) else null
            val hostPort = if (at >= 0) s.substring(at + 1) else s
            val colon = hostPort.lastIndexOf(':')
            if (colon <= 0) return null
            val port = hostPort.substring(colon + 1).toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val host = hostPort.substring(0, colon).removePrefix("[").removeSuffix("]")
            if (host.isEmpty()) return null
            val user = credentials?.substringBefore(':')?.takeIf { it.isNotEmpty() }
            val pass = if (user == null) null else credentials.substringAfter(':', "")
            return LookupProxy(host, port, user, pass)
        }
    }
}

/** One ip-api.com answer: where IRNet's traffic comes out. */
data class IpInfo(
    val countryCode: String,
    val country: String,
    val regionName: String,
    val city: String,
    val isp: String,
    val ip: String,
    val lat: Double?,
    val lon: Double?,
) {
    /** The shape the Dart side gets from ip-api.com itself. */
    fun toMap(): Map<String, Any?> = mapOf(
        "countryCode" to countryCode,
        "country" to country,
        "regionName" to regionName,
        "city" to city,
        "isp" to isp,
        "query" to ip,
        "lat" to lat,
        "lon" to lon,
    )

    fun toJson(): String {
        val o = JSONObject()
        for ((k, v) in toMap()) if (v != null) o.put(k, v)
        return o.toString()
    }

    /** "🇩🇪" for "DE"; empty for anything that isn't two letters. */
    val flag: String
        get() {
            val cc = countryCode.uppercase()
            if (cc.length != 2 || !cc.all { it in 'A'..'Z' }) return ""
            return cc.map { String(Character.toChars(0x1F1E6 - 'A'.code + it.code)) }.joinToString("")
        }

    companion object {
        fun parse(body: String?): IpInfo? {
            if (body.isNullOrBlank()) return null
            val o = try {
                JSONObject(body)
            } catch (e: Exception) {
                return null
            }
            if (o.optString("status") == "fail") return null
            val cc = o.optString("countryCode")
            if (cc.isBlank()) return null
            fun num(key: String) = if (o.has(key)) o.optDouble(key).takeIf { !it.isNaN() } else null
            return IpInfo(
                countryCode = cc,
                country = o.optString("country"),
                regionName = o.optString("regionName"),
                city = o.optString("city"),
                isp = o.optString("isp"),
                ip = o.optString("query"),
                lat = num("lat"),
                lon = num("lon"),
            )
        }
    }
}

sealed class LookupOutcome {
    data class Found(val info: IpInfo) : LookupOutcome()

    /** The proxy refused the connection: the VPN behind it has stopped. */
    object ProxyDown : LookupOutcome()

    /**
     * The proxy turned the password down: it belongs to an earlier
     * connection (the VPN reconnected on the same port).
     */
    object ProxyRejected : LookupOutcome()
    data class Failed(val reason: String) : LookupOutcome()
}

/**
 * The same lookup the Dart side does on desktop: the public IP from
 * ipify (HTTPS), then its location from ip-api.com. If ipify can't be
 * reached, ip-api.com reports the address it sees itself.
 */
class IpLookup(
    private val ipifyUrl: String = "https://api.ipify.org",
    private val ipApiBase: String = "http://ip-api.com/json/",
    private val timeoutMs: Int = 8_000,
) {
    fun run(proxy: LookupProxy?): LookupOutcome {
        currentProxy = proxy
        val ip = try {
            fetch(ipifyUrl, proxy).trim().takeIf { IP.matches(it) }
        } catch (e: Exception) {
            proxyProblem(e, proxy)?.let { return it }
            null
        }
        return try {
            val body = fetch("$ipApiBase${ip ?: ""}?fields=$FIELDS", proxy)
            IpInfo.parse(body)?.let { LookupOutcome.Found(it) } ?: LookupOutcome.Failed("no location in the answer")
        } catch (e: Exception) {
            proxyProblem(e, proxy) ?: LookupOutcome.Failed(e.toString())
        }
    }

    /** What [e] says about the proxy, if anything. */
    private fun proxyProblem(e: Exception, proxy: LookupProxy?): LookupOutcome? = when {
        proxy == null -> null
        e is ConnectException -> LookupOutcome.ProxyDown
        e is ProxyAuthException -> LookupOutcome.ProxyRejected
        // Android's client answers a 407 through the Authenticator; a wrong
        // password makes it retry until it gives up with this.
        e is ProtocolException && e.message?.contains("follow-up", ignoreCase = true) == true -> LookupOutcome.ProxyRejected
        else -> null
    }

    private class ProxyAuthException : IOException("Proxy authentication required")

    private fun fetch(url: String, proxy: LookupProxy?): String {
        val u = URL(url)
        val route = if (proxy == null) Proxy.NO_PROXY else Proxy(Proxy.Type.HTTP, InetSocketAddress(proxy.host, proxy.port))
        val conn = u.openConnection(route) as HttpURLConnection
        conn.connectTimeout = timeoutMs
        conn.readTimeout = timeoutMs
        conn.useCaches = false
        conn.instanceFollowRedirects = false
        conn.setRequestProperty("User-Agent", "IRNet")
        // Plain HTTP goes to the proxy as is: authenticate up front. HTTPS
        // tunnels answer the proxy's 407 through the Authenticator below.
        val auth = proxy?.basicAuth
        if (auth != null && u.protocol == "http") conn.setRequestProperty("Proxy-Authorization", auth)
        try {
            val code = conn.responseCode
            if (code == HttpURLConnection.HTTP_PROXY_AUTH) throw ProxyAuthException()
            if (code !in 200..299) throw IOException("HTTP $code from ${u.host}")
            return conn.inputStream.bufferedReader().use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        /** query, isp, lat, lon, city, regionName, countryCode, country. */
        const val FIELDS = 8923
        private val IP = Regex("^[0-9A-Fa-f:.]{3,45}$")

        @Volatile
        private var currentProxy: LookupProxy? = null
        private var installed = false

        /** Answers the VPN proxy's password prompt for HTTPS tunnels, and nothing else. */
        @Synchronized
        fun installAuthenticator() {
            if (installed) return
            installed = true
            Authenticator.setDefault(object : Authenticator() {
                override fun getPasswordAuthentication(): PasswordAuthentication? {
                    val p = currentProxy ?: return null
                    if (requestorType != RequestorType.PROXY || requestingPort != p.port || p.user == null) return null
                    return PasswordAuthentication(p.user, (p.pass ?: "").toCharArray())
                }
            })
        }
    }
}
