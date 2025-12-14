import 'package:flutter/material.dart';

import '../main.dart';

class Connection extends StatefulWidget {
  const Connection({super.key});

  @override
  State<Connection> createState() => _ConnectionState();
}

class _ConnectionState extends State<Connection> {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400,
      height: 100,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.blueAccent),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          results(),
          const SizedBox(width: 24),
          testButton(),
        ],
      ),
    );
  }

  Widget results() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        pingRow(),
        downloadRow(),
        uploadRow(),
      ],
    );
  }

  Widget pingRow() {
    return StreamBuilder(
      stream: bloc.ping,
      builder: (context, snapshot) {
        final value = snapshot.data ?? 0.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.timer, color: Colors.teal, size: 18),
            const SizedBox(width: 4),
            Text(
              'Ping: ${value.toInt()} ms',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.teal, fontWeight: FontWeight.bold),
            )
          ],
        );
      },
    );
  }

  Widget downloadRow() {
    return StreamBuilder(
      stream: bloc.downloadSpeed,
      builder: (context, snapshot) {
        final value = (snapshot.data ?? 0.0).toInt();
        final formattedValue = value == 0 ? '--' : '${value.toInt()} Mb/s';
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Icon(Icons.download, color: Colors.deepOrange, size: 18),
            const SizedBox(width: 4),
            Text(
              'Download speed: $formattedValue',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16, color: Colors.deepOrange, fontWeight: FontWeight.bold),
            ),
          ],
        );
      },
    );
  }

  Widget uploadRow() {
    return StreamBuilder(
      stream: bloc.uploadSpeed,
      builder: (context, snapshot) {
        var value = (snapshot.data ?? 0.0).toInt();
        if (value > 500) {
          value = 0;
        }
        final formattedValue = value == 0 ? '--' : '${value.toInt()} Mb/s';
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Icon(Icons.upload, color: Colors.deepPurple, size: 18),
            const SizedBox(width: 4),
            Text(
              'Upload speed: $formattedValue',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16, color: Colors.deepPurple, fontWeight: FontWeight.bold),
            ),
          ],
        );
      },
    );
  }

  Widget testButton() {
    return StreamBuilder(stream: bloc.speedTestStatus, builder: (context, snapshot) {
      final value = snapshot.data ?? 'Not started';

      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: () {
              if (value != 'Running') {
                bloc.onConnectionTestClick();
              }
            },
            style: ElevatedButton.styleFrom(
              shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
              backgroundColor: value == 'Running' ? Colors.grey : Colors.blue,
            ),
            child: const Text('Test', style: TextStyle(color: Colors.white, fontSize: 18)),
          ),
          const SizedBox(height: 4),
          if (value == 'Running')
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator())
          else
            Text(value)
        ],
      );
    });
  }
}
