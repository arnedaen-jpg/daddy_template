import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../config/env_config.dart';
import '../../utils/s.dart';
import 'device_info_manager.dart';

/// 网络客户端
/// 基于 Dio 封装，支持环境切换、自动添加设备信息头
class HttpClient {
  static final HttpClient _instance = HttpClient._internal();
  factory HttpClient() => _instance;
  HttpClient._internal();

  late Dio _dio;
  bool _isInitialized = false;

  /// 初始化
  Future<void> initialize() async {
    if (_isInitialized) return;

    // 初始化设备信息
    await DeviceInfoManager().initialize();

    _dio = Dio(_createBaseOptions());

    // 添加拦截器
    _dio.interceptors.addAll([
      _HeaderInterceptor(),
      _LogInterceptor(),
    ]);

    _isInitialized = true;
  }

  /// 创建基础配置
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

  /// 切换环境后更新 baseUrl
  void updateBaseUrl() {
    _dio.options.baseUrl = EnvConfig.apiBaseUrl;
  }

  /// GET 请求
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

  /// POST 请求
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

  /// PUT 请求
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

  /// DELETE 请求
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

  /// 获取 Dio 实例（用于特殊场景）
  Dio get dio => _dio;
}

/// 请求头拦截器
/// 自动添加设备信息到请求头
class _HeaderInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final deviceInfo = DeviceInfoManager();

    // 添加设备信息头
    final deviceHeaders = deviceInfo.getRequestHeaders();
    options.headers.addAll(deviceHeaders);

    // 添加自定义 User-Agent
    options.headers['User-Agent'] = deviceInfo.userAgent;

    options.headers[S.xEnvHeader] = EnvConfig.current.name;

    handler.next(options);
  }
}

/// 日志拦截器
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
