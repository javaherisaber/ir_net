import 'dart:collection';
import 'dart:math';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:latlng/latlng.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:map/map.dart';
import 'main.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({Key? key}) : super(key: key);

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
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
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              locationTag(),
              const SizedBox(height: 16),
              map(),
              const SizedBox(height: 32),
              lookupResult(),
              const SizedBox(height: 24),
              SizedBox(
                width: 300,
                child: launchAtStartup(),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  exitButton(),
                  const SizedBox(width: 16),
                  refreshButton(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget launchAtStartup() {
    return FutureBuilder<bool>(
      future: LaunchAtStartup.instance.isEnabled(),
      builder: (context, snapshot) {
        final value = snapshot.data ?? false;
        return CheckboxListTile(
          title: const Text('Launch on windows startup?'),
          value: value,
          onChanged: (enabled) {
            if (enabled == true) {
              LaunchAtStartup.instance.enable();
            } else {
              LaunchAtStartup.instance.disable();
            }
            setState(() {});
          },
        );
      },
    );
  }

  Widget exitButton() {
    return ElevatedButton(
      style: ButtonStyle(minimumSize: MaterialStateProperty.all(const Size(80, 56))),
      onPressed: bloc.onExitClick,
      child: const Text('Exit'),
    );
  }

  Widget refreshButton() {
    return ElevatedButton(
      style: ButtonStyle(minimumSize: MaterialStateProperty.all(const Size(80, 56))),
      onPressed: bloc.onRefreshButtonClick,
      child: const Text('Refresh'),
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
          return Text('No data');
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
