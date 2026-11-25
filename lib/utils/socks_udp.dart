import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// UDP through a SOCKS5 proxy (RFC 1928 UDP ASSOCIATE), e.g. the VPN's local
/// SOCKS inbound.
///
/// On Android IRNet is kept out of its own VPN, so its UDP probes take this
/// way to measure the path the other apps' UDP takes (tun2socks hands their
/// UDP to the same inbound). Destinations go as names, so the VPN resolves
/// them, not the local network.
class SocksUdpAssociation {
  SocksUdpAssociation._(this._control, this._socket, this.relay, this.relayPort) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? d;
      while ((d = _socket.receive()) != null) {
        // Only the relay speaks to us; anything else is noise.
        if (d!.port != relayPort || d.address != relay) continue;
        final payload = parseSocksUdp(d.data);
        if (payload != null) _datagrams.add(payload);
      }
    }, onError: (_) => close(), onDone: close);
  }

  final _ControlConnection _control;
  final RawDatagramSocket _socket;
  final _datagrams = StreamController<Uint8List>.broadcast();

  /// Where the proxy relays this association's datagrams.
  final InternetAddress relay;
  final int relayPort;
  bool _closed = false;

  bool get isOpen => !_closed;

  /// Payloads arriving from the far side, SOCKS header removed.
  Stream<Uint8List> get datagrams => _datagrams.stream;

  /// Opens an association through the no-auth SOCKS5 proxy at [proxy]
  /// ("host:port"). Throws [SocketException] or [TimeoutException].
  static Future<SocksUdpAssociation> open(String proxy, {Duration timeout = const Duration(seconds: 5)}) async {
    final colon = proxy.lastIndexOf(':');
    final host = proxy.substring(0, colon).replaceAll('[', '').replaceAll(']', '');
    final port = int.parse(proxy.substring(colon + 1));
    final deadline = DateTime.now().add(timeout);
    Duration left() {
      final d = deadline.difference(DateTime.now());
      if (d <= Duration.zero) throw TimeoutException('SOCKS5 UDP ASSOCIATE');
      return d;
    }

    final socket = await Socket.connect(host, port, timeout: left());
    final control = _ControlConnection(socket);
    RawDatagramSocket? udp;
    try {
      // No authentication (the VPN's inbound listens on loopback only).
      socket.add(const [5, 1, 0]);
      final method = await control.read(2).timeout(left());
      if (method[0] != 5 || method[1] != 0) {
        throw const SocketException('The SOCKS5 proxy wants authentication');
      }
      // UDP ASSOCIATE from 0.0.0.0:0: "any port on the address this TCP
      // connection comes from" (Xray v26 then accepts our UDP socket's port).
      socket.add(const [5, 3, 0, 1, 0, 0, 0, 0, 0, 0]);
      final head = await control.read(4).timeout(left());
      if (head[0] != 5 || head[1] != 0) {
        throw SocketException('The SOCKS5 proxy refused UDP (reply ${head[1]})');
      }
      final InternetAddress bound;
      switch (head[3]) {
        case 1:
          bound = InternetAddress.fromRawAddress(await control.read(4).timeout(left()));
        case 4:
          bound = InternetAddress.fromRawAddress(await control.read(16).timeout(left()));
        case 3:
          final length = (await control.read(1).timeout(left()))[0];
          final name = ascii.decode(await control.read(length).timeout(left()));
          bound = (await InternetAddress.lookup(name).timeout(left())).first;
        default:
          throw const SocketException('Malformed SOCKS5 reply');
      }
      final portBytes = await control.read(2).timeout(left());
      final relayPort = portBytes[0] << 8 | portBytes[1];
      // An unspecified address means "the proxy's own address".
      final relay = bound.rawAddress.every((b) => b == 0) ? socket.remoteAddress : bound;
      udp = await RawDatagramSocket.bind(
        relay.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
        0,
      );
      final association = SocksUdpAssociation._(control, udp, relay, relayPort);
      // The association lives as long as this TCP connection.
      control.onClosed = association.close;
      return association;
    } catch (_) {
      udp?.close();
      socket.destroy();
      rethrow;
    }
  }

  /// Sends [payload] to [host]:[port] through the proxy; returns false when
  /// the datagram could not be handed to the network.
  bool send(Uint8List payload, String host, int port) {
    if (_closed) return false;
    final datagram = buildSocksUdp(payload, host, port);
    return _socket.send(datagram, relay, relayPort) == datagram.length;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _socket.close();
    _control.destroy();
    _datagrams.close();
  }
}

/// A SOCKS5 UDP request: RSV(2) FRAG(1) ATYP DST.ADDR DST.PORT DATA.
Uint8List buildSocksUdp(Uint8List payload, String host, int port) {
  final ip = InternetAddress.tryParse(host);
  final List<int> address;
  if (ip == null) {
    final name = ascii.encode(host);
    address = [3, name.length, ...name];
  } else {
    address = [ip.type == InternetAddressType.IPv6 ? 4 : 1, ...ip.rawAddress];
  }
  return Uint8List.fromList([0, 0, 0, ...address, port >> 8 & 0xff, port & 0xff, ...payload]);
}

/// The payload of a SOCKS5 UDP reply, or null when it's malformed or a
/// fragment (fragments are not supported, as by most proxies).
Uint8List? parseSocksUdp(Uint8List data) {
  if (data.length < 4 || data[2] != 0) return null;
  final int offset;
  switch (data[3]) {
    case 1:
      offset = 4 + 4;
    case 4:
      offset = 4 + 16;
    case 3:
      if (data.length < 5) return null;
      offset = 5 + data[4];
    default:
      return null;
  }
  if (data.length < offset + 2) return null;
  return Uint8List.sublistView(data, offset + 2);
}

/// The association's TCP connection: reads the handshake, then just waits.
class _ControlConnection {
  _ControlConnection(this.socket) {
    socket.listen((data) {
      _buffer.addAll(data);
      _wake();
    }, onError: (Object e) {
      _closed = true;
      _wake(e);
      onClosed?.call();
    }, onDone: () {
      _closed = true;
      _wake();
      onClosed?.call();
    }, cancelOnError: true);
  }

  final Socket socket;
  final _buffer = <int>[];
  Completer<void>? _more;
  bool _closed = false;
  void Function()? onClosed;

  void _wake([Object? error]) {
    final c = _more;
    _more = null;
    if (c == null || c.isCompleted) return;
    error == null ? c.complete() : c.completeError(error);
  }

  Future<Uint8List> read(int n) async {
    while (_buffer.length < n) {
      if (_closed) throw const SocketException('The SOCKS5 proxy closed the connection');
      await (_more = Completer<void>()).future;
    }
    final out = Uint8List.fromList(_buffer.sublist(0, n));
    _buffer.removeRange(0, n);
    return out;
  }

  void destroy() {
    onClosed = null;
    socket.destroy();
  }
}
