import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../config/environment.dart';
import 'auth_service.dart';

class ApiClient {
  final AuthService _authService = AuthService();

  Future<http.Response> get(
    String endpoint, {
    BuildContext? context,
  }) async {
    final token = await _authService.getToken();

    final response = await http.get(
      Uri.parse('${Environment.backendUrl}$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
    );

    if (context != null && context.mounted) {
      return _handleResponse(response, context);
    }

    return response;
  }

  Future<http.Response> post(
    String endpoint,
    Map<String, dynamic> body, {
    BuildContext? context,
  }) async {
    final token = await _authService.getToken();

    final response = await http.post(
      Uri.parse('${Environment.backendUrl}$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: jsonEncode(body),
    );

    if (context != null && context.mounted) {
      return _handleResponse(response, context);
    }

    return response;
  }

  http.Response _handleResponse(http.Response response, BuildContext? context) {
    if (response.statusCode == 401) {
      _authService.clearAuthData();

      if (context != null && context.mounted) {
        _showSessionExpiredDialog(context);
      }
    }

    return response;
  }

  void _showSessionExpiredDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Session Expired'),
        content: const Text('Your session has expired. Please log in again.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pushNamedAndRemoveUntil(
                '/',
                (route) => false,
              );
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
