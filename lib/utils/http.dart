import 'dart:io';

import 'package:dio/dio.dart';

class HttpUtils {
  static final Dio _dio = Dio();

  static Future<double> measureHttpPing({
    String url = "https://www.gstatic.com/generate_204",
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _dio.options = BaseOptions(headers: {
      HttpHeaders.connectionHeader: 'keep-alive', // Ensure keep-alive headers
    });
    try {
      await _dio.head(url).timeout(timeout); // just a warm up connection to get a reliable result
      final firstTime = DateTime.now().millisecondsSinceEpoch;
      final response = await _dio.head(url).timeout(timeout);
      final secondTime = DateTime.now().millisecondsSinceEpoch;
      if (response.statusCode == 200 || response.statusCode == 204) {
        return (secondTime - firstTime).toDouble();
      } else {
        return 0; // server responded but with an error
      }
    } on Exception catch (_) {
      return 0; // timeout or unreachable
    }
  }
}
