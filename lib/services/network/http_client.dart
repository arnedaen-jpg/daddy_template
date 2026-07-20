import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../config/env_config.dart';
import '../../utils/cdn_sign_utils.dart';
import '../../utils/s.dart';
import '../domain_manager.dart';
import 'device_info_manager.dart';

/// 网络客户端
/// 基于 Dio 封装：环境切换、设备头、CDN URL 加签（对齐 XMSport / dqiu）
class HttpClient {
  static final HttpClient _instance = HttpClient._internal();
  factory HttpClient() => _instance;
  HttpClient._internal();

  late Dio _dio;
  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;

    await DeviceInfoManager().initialize();

    _dio = Dio(_createBaseOptions());
    _dio.interceptors.addAll([
      _CdnSignInterceptor(),
      _HeaderInterceptor(),
      _LogInterceptor(),
    ]);

    _isInitialized = true;
  }

  BaseOptions _createBaseOptions() {
    return BaseOptions(
      baseUrl: EnvConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    );
  }

  /// 切换环境或域名池更新后刷新 baseUrl
  void updateBaseUrl() {
    if (!_isInitialized) return;
    final domain = DomainManager().currentDomain()?.domain ?? EnvConfig.apiBaseUrl;
    _dio.options.baseUrl = domain;
  }

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.get<T>(
      path,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> post<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.post<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> put<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.put<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Future<Response<T>> delete<T>(
    String path, {
    dynamic data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) {
    return _dio.delete<T>(
      path,
      data: data,
      queryParameters: queryParameters,
      options: options,
      cancelToken: cancelToken,
    );
  }

  Dio get dio => _dio;
}

/// CDN 加签拦截器（对齐 dqiu HttpManager / XMSport）
class _CdnSignInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      final uri = options.uri;
      final host = '${uri.scheme}://${uri.host}';
      final entity = DomainManager().getDomain(host) ??
          DomainManager().getDomain(options.baseUrl);

      if (entity != null && entity.domainType > 0 && entity.openFlag) {
        var urlStr = uri.toString();
        urlStr = CdnSignUtils.maybeSignUrl(
          urlStr,
          domainType: entity.domainType,
          openFlag: entity.openFlag,
          token: entity.token,
          signType: entity.signType,
        );
        final signed = Uri.parse(urlStr);
        options.path = signed.hasQuery
            ? '${signed.path}?${signed.query}'
            : signed.path;
        if (options.method.toUpperCase() == 'GET') {
          options.queryParameters = {};
        }
      }
    } catch (_) {}
    handler.next(options);
  }
}

class _HeaderInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final deviceInfo = DeviceInfoManager();
    options.headers.addAll(deviceInfo.getRequestHeaders());
    options.headers['User-Agent'] = deviceInfo.userAgent;
    options.headers[S.xEnvHeader] = EnvConfig.current.name;
    handler.next(options);
  }
}

class _LogInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (kDebugMode) {
      print('┌──────────────────────────────────────────');
      print('│ [REQUEST] ${options.method} ${options.uri}');
      print('│ Headers: ${options.headers}');
      if (options.data != null) {
        print('│ Body: ${options.data}');
      }
      print('└──────────────────────────────────────────');
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (kDebugMode) {
      print('┌──────────────────────────────────────────');
      print('│ [RESPONSE] ${response.statusCode} ${response.requestOptions.uri}');
      print('│ Data: ${response.data}');
      print('└──────────────────────────────────────────');
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (kDebugMode) {
      print('┌──────────────────────────────────────────');
      print('│ [ERROR] ${err.type} ${err.requestOptions.uri}');
      print('│ Message: ${err.message}');
      print('└──────────────────────────────────────────');
    }
    handler.next(err);
  }
}
