import 'dart:collection';
import 'dart:math';

import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';
import 'package:ir_net/main.dart';
import 'package:ir_net/utils/cmd.dart';

class IpStatView extends StatefulWidget {
  const IpStatView({super.key});

  @override
  State<IpStatView> createState() => _IpStatViewState();
}

class _IpStatViewState extends State<IpStatView> {

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        lookupResult(),
        const SizedBox(height: 16),
        networkInfo(),
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
      var interfaceName = inf.interfaceName;
      if (interfaceName.length > 10) {
        interfaceName = "${interfaceName.substring(0, 5)}...${interfaceName.substring(interfaceName.length - 5)}";
      }
      result += '${inf.ipv4} ($interfaceName)';
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

        final map = data as LinkedHashMap;
        final countryCode = map['countryCode'];
        final entries = map.entries
            .where((e) => e.key != 'lat' && e.key != 'lon' && e.key != 'query' && e.key != 'countryCode')
            .toList();
        if (entries.isEmpty) {
          return const SizedBox.shrink();
        }

        final longestLength =
        entries.map((e) => e.key.toString().length).fold(0, max);
        final keyColumnWidth = (longestLength * 8.0).clamp(120.0, 280.0);

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 6),
            itemBuilder: (context, index) {
              final e = entries[index];
              return Container(
                color: Colors.black12,
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: keyColumnWidth,
                      child: Text(
                        e.key.toString(),
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Row(
                        children: [
                          Text(
                            '${e.value}',
                            softWrap: true,
                          ),
                          if (e.key == 'country')
                            const SizedBox(width: 16),
                          if (e.key == 'country')
                            CountryFlag.fromCountryCode(
                              countryCode,
                              theme: const ImageTheme(
                                height: 20,
                                width: 30,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
