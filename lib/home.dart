import 'package:flutter/material.dart';
import 'package:ir_net/views/connection.dart';
import 'package:ir_net/views/ip_stat.dart';
import 'package:ir_net/views/leak.dart';
import 'package:ir_net/views/options.dart';

import 'main.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LeakView(),
                  SizedBox(width: 64),
                  IpStatView(),
                ],
              ),
              const SizedBox(height: 16),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppOptions(),
                  SizedBox(width: 64),
                  Connection()
                ],
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
}
