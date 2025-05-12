import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class KerioLoginPage extends StatefulWidget {
  @override
  _KerioLoginPageState createState() => _KerioLoginPageState();
}

class _KerioLoginPageState extends State<KerioLoginPage> {
  final TextEditingController _ipController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final _storage = FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _attemptAutoLogin();
  }

  Future<void> _attemptAutoLogin() async {
    final ip = await _storage.read(key: 'kerio_ip');
    final username = await _storage.read(key: 'kerio_username');
    final password = await _storage.read(key: 'kerio_password');

    if (ip != null && username != null && password != null) {
      _ipController.text = ip;
      _usernameController.text = username;
      _passwordController.text = password;
      _login();
    }
  }

  void _login() async {
    final ip = _ipController.text;
    final username = _usernameController.text;
    final password = _passwordController.text;

    if (ip.isEmpty || username.isEmpty || password.isEmpty) {
      _showMessage('Please fill in all fields');
      return;
    }

    // Save credentials for auto-login
    await _storage.write(key: 'kerio_ip', value: ip);
    await _storage.write(key: 'kerio_username', value: username);
    await _storage.write(key: 'kerio_password', value: password);

    final url = 'http://$ip/internal/dologin.php';
    final response = await http.post(
      Uri.parse(url),
      body: {
        'kerio_username': username,
        'kerio_password': password,
      },
    );

    if (response.statusCode == 200) {
      _showMessage('Login successful');
    } else {
      _showMessage('Login failed');
    }
  }

  void _showMessage(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Kerio Login'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _ipController,
              decoration: InputDecoration(labelText: 'Kerio Login Page IP'),
              keyboardType: TextInputType.url,
            ),
            TextField(
              controller: _usernameController,
              decoration: InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(labelText: 'Password'),
              obscureText: true,
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _login,
              child: Text('Login'),
            ),
          ],
        ),
      ),
    );
  }
}
