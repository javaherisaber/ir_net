import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:ir_net/data/shared_preferences.dart';
import 'package:ir_net/utils/kerio.dart';
import 'package:url_launcher/url_launcher.dart';

class KerioLoginView extends StatefulWidget {
  const KerioLoginView({super.key});

  @override
  State<KerioLoginView> createState() => _KerioLoginViewState();
}

class _KerioLoginViewState extends State<KerioLoginView> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _attemptAutoLogin();
  }

  Future<void> _attemptAutoLogin() async {
    final ip = await AppSharedPreferences.kerioIP;
    final username = await AppSharedPreferences.kerioUsername;
    final password = await AppSharedPreferences.kerioPassword;
    final enabled = await AppSharedPreferences.kerioAutoLogin;

    _ipController.text = ip ?? '';
    if (ip != null && username != null && password != null && enabled == true) {
      _ipController.text = ip;
      _usernameController.text = username;
      _passwordController.text = password;
      _login(true);
    }
  }

  void _login(bool auto) async {
    final ip = _ipController.text;
    final username = _usernameController.text;
    final password = _passwordController.text;

    if (ip.isEmpty || username.isEmpty || password.isEmpty) {
      _showMessage('Please fill in all fields');
      return;
    }

    // Save credentials for auto-login
    await AppSharedPreferences.setKerioIP(ip);
    await AppSharedPreferences.setKerioUsername(username);
    await AppSharedPreferences.setKerioPassword(password);

    final url = 'http://$ip/internal/dologin.php';
    final response = await http.post(
      Uri.parse(url),
      body: {
        'kerio_username': username,
        'kerio_password': password,
      },
    );

    if (auto) {
      return;
    }

    _showMessage('Login request sent'); // todo: handle failure case
  }

  void _showMessage(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ipAndBalanceRow(),
          const SizedBox(height: 4),
          credentialsRow(),
          const SizedBox(height: 8),
          loginRow()
        ],
      ),
    );
  }

  Widget ipAndBalanceRow() {
    return Row(
      children: [
        Expanded(
          child: ipInput(),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: balance(),
        ),
      ],
    );
  }

  Widget balance() {
    return FutureBuilder(
      future: KerioUtils.getAccountBalance(),
      builder: (context, snapshot) {
        var (total, remaining) = snapshot.data ?? (0, 0);
        var totalFormatted = total == 0 ? '--' : KerioUtils.formatBytes(total);
        var remainingFormatted = remaining == 0 ? '--' : KerioUtils.formatBytes(remaining);
        return Container(
          padding: const EdgeInsets.only(left: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Remaining =  $remainingFormatted',
                style: TextStyle(color: remaining < 1073741824 ? Colors.red : Colors.black),
              ),
              Text('Total          =  $totalFormatted'),
            ],
          ),
        );
      },
    );
  }

  Widget ipInput() {
    return TextField(
      controller: _ipController,
      decoration: InputDecoration(
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.green),
        ),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: Colors.blue),
        ),
        hintText: 'Kerio login page IP',
        hintStyle: const TextStyle(color: Colors.black38),
        suffixIcon: IconButton(
          onPressed: () {
            final url = _ipController.text.trim();
            if (url.isNotEmpty) {
              final uri = Uri.tryParse(url.startsWith('http') ? url : 'http://$url');
              if (uri != null) {
                launchUrl(uri);
              }
            }
          },
          icon: Image.asset('assets/kerio.png', width: 24, height: 24),
        ),
      ),
      keyboardType: TextInputType.url,
    );
  }

  Widget credentialsRow() {
    return Row(
      children: [
        Expanded(
          child: username(),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: password(),
        ),
      ],
    );
  }

  Widget username() {
    return TextField(
      controller: _usernameController,
      decoration: const InputDecoration(
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.green),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.blue),
        ),
        hintText: 'Username',
        hintStyle: TextStyle(color: Colors.black38),
      ),
    );
  }

  Widget password() {
    return TextField(
      controller: _passwordController,
      decoration: const InputDecoration(
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.green),
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: Colors.blue),
        ),
        hintText: 'Password',
        hintStyle: TextStyle(color: Colors.black38),
      ),
      obscureText: true,
    );
  }

  Widget loginRow() {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: ElevatedButton(
            onPressed: () => _login(false),
            style: ElevatedButton.styleFrom(
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              backgroundColor: Colors.blue,
            ),
            child: const Text('Login', style: TextStyle(color: Colors.white)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: autoLoginOption(),
        )
      ],
    );
  }

  Widget autoLoginOption() {
    return FutureBuilder<bool>(
      future: AppSharedPreferences.kerioAutoLogin,
      builder: (context, snapshot) {
        final value = snapshot.data ?? false;
        return CheckboxListTile(
          title: const Text('Auto?'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          value: value,
          onChanged: (enabled) async {
            await AppSharedPreferences.setKerioAutoLogin(enabled ?? false);
            setState(() {});
          },
        );
      },
    );
  }
}
