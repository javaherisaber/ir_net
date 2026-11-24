package com.buildtoapp.ir_net

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.Collections
import kotlin.concurrent.thread

/** Just enough HTTP/1.1 to answer one request per connection (origin- or absolute-form). */
private class TinyServer(private val handle: (target: String, headers: Map<String, String>) -> Pair<Int, String>) :
    AutoCloseable {
    private val socket = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    val port: Int get() = socket.localPort

    init {
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (e: Exception) {
                    break
                }
                thread(isDaemon = true) { client.use { serve(it) } }
            }
        }
    }

    private fun serve(s: Socket) {
        val reader = s.getInputStream().bufferedReader()
        val requestLine = reader.readLine() ?: return
        val headers = mutableMapOf<String, String>()
        while (true) {
            val line = reader.readLine() ?: break
            if (line.isEmpty()) break
            val i = line.indexOf(':')
            if (i > 0) headers[line.substring(0, i).trim().lowercase()] = line.substring(i + 1).trim()
        }
        val (code, body) = handle(requestLine.split(' ')[1], headers)
        val bytes = body.toByteArray()
        val out = s.getOutputStream()
        out.write("HTTP/1.1 $code Status\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(bytes)
        out.flush()
    }

    override fun close() = socket.close()
}

class IpLookupTest {
    private val answer = """{"country":"Germany","countryCode":"DE","regionName":"Hesse","city":"Frankfurt",""" +
        """"lat":50.1,"lon":8,"isp":"Example GmbH","query":"203.0.113.7"}"""

    private lateinit var server: TinyServer
    private val requests: MutableList<String> = Collections.synchronizedList(mutableListOf())
    private val proxyAuth: MutableList<String?> = Collections.synchronizedList(mutableListOf())
    private var ipifyStatus = 200

    /** Answer proxied requests with 407, like Xray given an old password. */
    private var rejectProxy = false

    private val port get() = server.port

    @Before
    fun setUp() {
        server = TinyServer { target, headers ->
            requests.add(target)
            proxyAuth.add(headers["proxy-authorization"])
            val path = URI(target).path
            when {
                rejectProxy && target.startsWith("http://") -> 407 to ""
                path == "/ip" -> ipifyStatus to (if (ipifyStatus == 200) "203.0.113.7\n" else "nope")
                path.startsWith("/json/") -> 200 to answer
                else -> 404 to ""
            }
        }
    }

    @After
    fun tearDown() = server.close()

    private fun local() = IpLookup(ipifyUrl = "http://127.0.0.1:$port/ip", ipApiBase = "http://127.0.0.1:$port/json/", timeoutMs = 3_000)

    @Test
    fun `looks up the public IP, then its location`() {
        val outcome = local().run(null)
        assertTrue(outcome.toString(), outcome is LookupOutcome.Found)
        val info = (outcome as LookupOutcome.Found).info
        assertEquals("DE", info.countryCode)
        assertEquals("203.0.113.7", info.ip)
        assertEquals(8.0, info.lon!!, 0.0)
        assertEquals(listOf("/ip", "/json/203.0.113.7?fields=8923"), requests.toList())
    }

    @Test
    fun `asks ip-api for the address it sees when ipify is unreachable`() {
        ipifyStatus = 403
        val outcome = local().run(null)
        assertTrue(outcome.toString(), outcome is LookupOutcome.Found)
        assertEquals("/json/?fields=8923", requests.last())
    }

    @Test
    fun `goes through the VPN's proxy with its password`() {
        val proxy = LookupProxy("127.0.0.1", port, "irnet", "s3cret")
        val lookup = IpLookup(ipifyUrl = "http://ipify.invalid/ip", ipApiBase = "http://ip-api.invalid/json/", timeoutMs = 3_000)
        val outcome = lookup.run(proxy)
        assertTrue(outcome.toString(), outcome is LookupOutcome.Found)
        assertEquals(listOf("http://ipify.invalid/ip", "http://ip-api.invalid/json/203.0.113.7?fields=8923"), requests.toList())
        assertEquals(listOf("Basic aXJuZXQ6czNjcmV0", "Basic aXJuZXQ6czNjcmV0"), proxyAuth.toList())
    }

    @Test
    fun `reports a proxy that turns the password down`() {
        rejectProxy = true
        val proxy = LookupProxy("127.0.0.1", port, "irnet", "old-password")
        val lookup = IpLookup(ipifyUrl = "http://ipify.invalid/ip", ipApiBase = "http://ip-api.invalid/json/", timeoutMs = 3_000)
        assertEquals(LookupOutcome.ProxyRejected, lookup.run(proxy))
    }

    @Test
    fun `reports a proxy that is gone, so the monitor looks up directly`() {
        val closed = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val outcome = local().run(LookupProxy("127.0.0.1", closed, "irnet", "x"))
        assertEquals(LookupOutcome.ProxyDown, outcome)
    }

    @Test
    fun `fails without a proxy when nothing answers`() {
        val closed = ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { it.localPort }
        val lookup = IpLookup(ipifyUrl = "http://127.0.0.1:$closed/ip", ipApiBase = "http://127.0.0.1:$closed/json/", timeoutMs = 2_000)
        assertTrue(lookup.run(null) is LookupOutcome.Failed)
    }

    @Test
    fun `parses the proxy the Dart side passes`() {
        val p = LookupProxy.parse("irnet:ab:cd@127.0.0.1:10809")!!
        assertEquals("127.0.0.1", p.host)
        assertEquals(10809, p.port)
        assertEquals("irnet", p.user)
        assertEquals("ab:cd", p.pass)
        assertEquals(LookupProxy("10.0.0.1", 3128, null, null), LookupProxy.parse("10.0.0.1:3128"))
        assertNull(LookupProxy.parse("10.0.0.1:3128")!!.basicAuth)
        assertEquals("::1", LookupProxy.parse("[::1]:1080")!!.host)
        for (bad in listOf(null, "", "  ", "nohost", ":80", "h:0", "h:70000", "h:x")) {
            assertNull(bad, LookupProxy.parse(bad))
        }
    }

    @Test
    fun `reads ip-api answers and keeps them across restarts`() {
        val info = IpInfo.parse(answer)!!
        assertEquals("Frankfurt", info.city)
        assertEquals(50.1, info.lat!!, 0.0)
        assertEquals("🇩🇪", info.flag)
        assertEquals(info, IpInfo.parse(info.toJson()))
        assertEquals("203.0.113.7", info.toMap()["query"])

        assertNull(IpInfo.parse("""{"status":"fail","message":"reserved range"}"""))
        assertNull(IpInfo.parse("""{"query":"10.0.0.1"}"""))
        assertNull(IpInfo.parse("<html>"))
        assertNull(IpInfo.parse(null))
        assertEquals("", IpInfo.parse("""{"countryCode":"X1","query":"1.2.3.4"}""")!!.flag)
    }
}
