import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/exam_config.dart';

/// Service to fetch and manage ExamBrowser configuration from the admin API.
class ConfigService {
  // Default API base URL - can be changed in settings
  static const String _defaultApiBaseUrl = 'https://simansa.man1metro.sch.id';
  static const String _configCacheKey = 'exam_config_cache';
  static const String _apiBaseUrlKey = 'api_base_url';
  static const String _supervisorPasswordKey = 'secure_supervisor_password';
  static ExamConfig? _runtimeConfig;

  final Dio _dio;
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

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
  Future<ExamConfig> fetchConfig({
    bool allowRuntimeFallback = true,
    bool allowCacheFallback = true,
    bool allowDefaultFallback = false,
  }) async {
    try {
      final baseUrl = await getApiBaseUrl();
      final response = await _dio.get('$baseUrl/api/exam-browser/config');

      if (response.statusCode == 200 && response.data['success'] == true) {
        final config = ExamConfig.fromJson(response.data['data']);
        _runtimeConfig = config;
        // Cache the config locally
        await _cacheConfig(config);
        await _cacheSupervisorPassword(config.supervisorPassword);
        return config;
      } else {
        throw Exception(response.data['message'] ?? 'Failed to fetch config');
      }
    } catch (e) {
      if (allowRuntimeFallback && _runtimeConfig != null) {
        return _runtimeConfig!;
      }

      // Try to use cached config
      if (allowCacheFallback) {
        final cached = await getCachedConfig();
        if (cached != null) return cached;
      }

      // Return defaults as last resort
      if (allowDefaultFallback) {
        return ExamConfig.defaults();
      }

      throw Exception('Gagal mengambil konfigurasi ujian dari server.');
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
    await prefs.setString(_configCacheKey, jsonEncode(config.toCacheJson()));
  }

  Future<void> _cacheSupervisorPassword(String? password) async {
    if (password == null || password.isEmpty) {
      await _secureStorage.delete(key: _supervisorPasswordKey);
      return;
    }
    await _secureStorage.write(key: _supervisorPasswordKey, value: password);
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
      throw Exception('Verifikasi password gagal karena server tidak dapat dihubungi.');
    }
  }

  Future<bool> hasSupervisorPassword() async {
    if (_runtimeConfig?.supervisorPassword != null &&
        _runtimeConfig!.supervisorPassword!.isNotEmpty) {
      return true;
    }
    final stored = await _secureStorage.read(key: _supervisorPasswordKey);
    return stored != null && stored.isNotEmpty;
  }

  Future<bool> verifySupervisorPassword(String password) async {
    final livePassword = _runtimeConfig?.supervisorPassword;
    if (livePassword != null && livePassword.isNotEmpty) {
      return livePassword == password;
    }

    final stored = await _secureStorage.read(key: _supervisorPasswordKey);
    return stored != null && stored.isNotEmpty && stored == password;
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
    await _secureStorage.delete(key: _supervisorPasswordKey);
  }
}
