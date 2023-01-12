import 'dart:collection';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/cmd.dart';
import 'package:latlng/latlng.dart';
import 'package:map/map.dart';

class IpStatView extends StatefulWidget {
  const IpStatView({super.key});

  @override
  State<IpStatView> createState() => _IpStatViewState();
}

class _IpStatViewState extends State<IpStatView> {
  late MapController controller;

  @override
  void initState() {
    controller = MapController(
      location: const LatLng(35.69439, 51.42151),
      zoom: 8,
    );
    bloc.latLng.listen((latLng) {
      setState(() {
        controller.center = latLng;
      });
    });
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        locationTag(),
        const SizedBox(height: 16),
        map(),
        const SizedBox(height: 16),
        networkInfo(),
        const SizedBox(height: 24),
        lookupResult(),
      ],
    );
  }

  Widget networkInfo() {
    return StreamBuilder<LocalNetworksResult>(
      stream: bloc.localNetwork,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const SizedBox.shrink();
        }
        return SizedBox(
          width: 400,
          child: Column(
            children: [
              ipAddress(),
              coloredText('DNS records:          ${data.dns[0]}, ${data.dns[1]}'),
              coloredText('Local IP Address:    ${_localIpText(data.interfaces)}')
            ],
          ),
        );
      },
    );
  }

  String _localIpText(List<NetworkInterface> interfaces) {
    var result = '';
    for (var i = 0; i < interfaces.length; i++) {
      final inf = interfaces[i];
      if (interfaces.length > 1 && i > 0 && i < interfaces.length) {
        result += '\n                               ';
      }
      result += '${inf.ipv4} (${inf.interfaceName})';
    }
    return result;
  }

  Widget ipAddress() {
    return StreamBuilder<dynamic>(
      stream: bloc.ipLookupResult,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const SizedBox.shrink();
        }
        return coloredText('Public IP address:   ${data['query']}');
      },
    );
  }

  Widget coloredText(String value) {
    return Container(
      color: Colors.black12,
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      child: Text(value),
    );
  }

  Widget lookupResult() {
    return StreamBuilder<dynamic>(
      stream: bloc.ipLookupResult,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const SizedBox.shrink();
        }
        var result = '';
        var longestLength = 1;
        for (MapEntry e in (data as LinkedHashMap).entries) {
          final len = e.key.toString().length;
          if (len > longestLength) {
            longestLength = len;
          }
        }
        for (MapEntry e in (data).entries) {
          final charCode = '.'.codeUnitAt(0);
          final dots = String.fromCharCodes(
            List.generate(longestLength - e.key.toString().length, (index) => charCode),
          );
          result += '${e.key} $dots................. ${e.value}\n';
        }
        return Text(result);
      },
    );
  }

  Widget locationTag() {
    return StreamBuilder<dynamic>(
      stream: bloc.ipLookupResult,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return const Text('No data');
        }
        return Text('${data['country']}, ${data['city']}');
      },
    );
  }

  Widget map() {
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox(
          width: 400,
          height: 150,
          child: mapLayout(),
        ),
      ],
    );
  }

  Widget mapLayout() {
    return MapLayout(
      controller: controller,
      builder: (context, transformer) {
        return TileLayer(
          builder: (context, x, y, z) {
            final tilesInZoom = pow(2.0, z).floor();
            while (x < 0) {
              x += tilesInZoom;
            }
            while (y < 0) {
              y += tilesInZoom;
            }
            x %= tilesInZoom;
            y %= tilesInZoom;
            final url = 'https://a.tile.openstreetmap.fr/hot/$z/$x/$y.png';

            return CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
            );
          },
        );
      },
    );
  }
}
