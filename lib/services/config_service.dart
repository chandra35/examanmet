import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/exam_config.dart';

/// Service to fetch and manage ExamBrowser configuration from the admin API.
class ConfigService {
  // Default API base URL - can be changed in settings
  static const String _defaultApiBaseUrl = 'https://simansa.man1metro.sch.id';
  static const String _configCacheKey = 'exam_config_cache';
  static const String _apiBaseUrlKey = 'api_base_url';

  final Dio _dio;

  ConfigService() : _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
    },
  ));

  /// Get the configured API base URL
  Future<String> getApiBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_apiBaseUrlKey) ?? _defaultApiBaseUrl;
  }

  /// Set the API base URL
  Future<void> setApiBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_apiBaseUrlKey, url);
  }

  /// Fetch config from API and cache it locally
  Future<ExamConfig> fetchConfig() async {
    try {
      final baseUrl = await getApiBaseUrl();
      final response = await _dio.get('$baseUrl/api/exam-browser/config');

      if (response.statusCode == 200 && response.data['success'] == true) {
        final config = ExamConfig.fromJson(response.data['data']);
        // Cache the config locally
        await _cacheConfig(config);
        return config;
      } else {
        throw Exception(response.data['message'] ?? 'Failed to fetch config');
      }
    } catch (e) {
      // Try to use cached config
      final cached = await getCachedConfig();
      if (cached != null) return cached;

      // Return defaults as last resort
      return ExamConfig.defaults();
    }
  }

  /// Get cached config from local storage
  Future<ExamConfig?> getCachedConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_configCacheKey);
      if (jsonStr != null) {
        final json = jsonDecode(jsonStr);
        return ExamConfig.fromJson(json);
      }
    } catch (_) {}
    return null;
  }

  /// Cache config locally
  Future<void> _cacheConfig(ExamConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configCacheKey, jsonEncode(config.toJson()));
  }

  /// Verify password with the API
  Future<bool> verifyPassword(String password, String type) async {
    try {
      final baseUrl = await getApiBaseUrl();
      final response = await _dio.post(
        '$baseUrl/api/exam-browser/verify-password',
        data: {
          'password': password,
          'type': type, // 'app' or 'exit'
        },
      );

      if (response.statusCode == 200) {
        return response.data['verified'] == true;
      }
      return false;
    } catch (e) {
      // Fallback: verify against cached config
      final config = await getCachedConfig();
      if (config != null) {
        if (type == 'exit') {
          return config.exitPassword == null ||
              config.exitPassword!.isEmpty ||
              config.exitPassword == password;
        } else {
          return config.appPassword == null ||
              config.appPassword!.isEmpty ||
              config.appPassword == password;
        }
      }
      return false;
    }
  }

  /// Ping the API to check connectivity
  Future<bool> ping() async {
    try {
      final baseUrl = await getApiBaseUrl();
      final response = await _dio.get(
        '$baseUrl/api/exam-browser/ping',
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      return response.statusCode == 200 && response.data['success'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Clear cached config
  Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_configCacheKey);
  }
}
