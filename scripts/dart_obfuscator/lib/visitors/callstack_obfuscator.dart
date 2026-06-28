import 'dart:io';
import 'dart:math';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as path;

import '../config.dart';
import '../utils/logger.dart';
import '../utils/name_generator.dart';

/// 调用栈混淆器
///
/// 在核心类的方法体中注入包装调用，增加调用栈深度
/// 这样代码会实际被执行，不会被 tree shaking 移除
class CallstackObfuscator {
  final ObfuscatorConfig config;
  final Logger logger;
  late final Random _random;

  CallstackObfuscator(this.config, this.logger) {
    // 使用时间戳作为随机种子，确保每次运行结果不同
    _random = Random(DateTime.now().millisecondsSinceEpoch);
  }

  /// 获取项目特定的核心文件列表（全量）
  List<String> _getAllCoreFiles(String projectName) {
    switch (projectName) {
      case 'ph':
        return [
          'api_service.dart', // HTTP 请求入口
          'user_service.dart', // 用户服务
          'app_service.dart', // 应用服务
          'app_prepare.dart', // 初始化
          'login.dart', // 登录 API
          'storage_service.dart', // 存储服务
        ];
      case 'hjsq':
        return [
          // 核心基础服务
          'base_service.dart',
          'account_service.dart',
          'user_service.dart',
          'repo.dart',

          // 业务服务 - 全量
          'home_service.dart',
          'order_service.dart',
          'withdraw_service.dart',
          'sign_service.dart',
          'proxy_service.dart',
          'search_service.dart',
          'rank_service.dart',
          'seed_service.dart',
          'message_service.dart',
          'privilege_service.dart',
          'community_service.dart',
          'dynamic_service.dart',
          'element_service.dart',
          'original_service.dart',

          // AI 全量服务
          'ai_service.dart',
          'aiaudio_service.dart',
          'ainovel_service.dart',
          'aidraw_service.dart',
          'aikiss_service.dart',
          'aimagic_service.dart',

          // 内容服务 - 全量
          'cartoon_service.dart',
          'game_service.dart',
          'live_service.dart',
          'mv_service.dart',
          'vlog_service.dart',
          'asmr_service.dart',

          // Repo mixin 层 - 全量
          'account_mixin.dart',
          'ai_mixin.dart',
          'aiaudio_mixin.dart',
          'aidraw_mixin.dart',
          'aikiss_mixin.dart',
          'aimagic_mixin.dart',
          'ainovel_mixin.dart',
          'asmr_mixin.dart',
          'cartoon_mixin.dart',
          'community_mixin.dart',
          'dynamic_mixin.dart',
          'element_mixin.dart',
          'game_mixin.dart',
          'home_mixin.dart',
          'live_mixin.dart',
          'message_mixin.dart',
          'mv_mixin.dart',
          'order_mixin.dart',
          'original_mixim.dart',
          'privilege_mixin.dart',
          'proxy_mixin.dart',
          'rank_mixin.dart',
          'search_mixin.dart',
          'seed_mixin.dart',
          'sign_mixin.dart',
          'user_mixin.dart',
          'vlog_mixin.dart',
          'withdraw_mixin.dart',

          // Repo 层
          'cache.dart',
          'http_interceptor.dart',
          'r2_uploader.dart',
          'utils.dart',

          // Domain 层
          'api_validator.dart',
          'domain.dart',
          'exception.dart',

          // App 层
          'module_entry.dart',
          'app_config.dart',
          'app_global.dart',
          'crypto.dart',
        ];
      case '51pc':
        return [
          // 核心网络与 API
          'api.dart',
          'http.dart',
          'api_path.dart',
          'http_image.dart',
          'image_request_async.dart',
          'netimage_tool.dart',
          'network_imagecrp.dart',

          // 加解密与安全
          'encdecrypt.dart',
          'local_crypto.dart',

          // 全局状态与存储
          'app_global.dart',
          'global.dart',
          'homeConfig.dart',
          'signInConfig.dart',
          'sharedPreferences.dart',
          'buy_status.dart',
          'sp_keys.dart',

          // 入口与路由
          'module_entry.dart',
          'main.dart',
          'routers.dart',

          // 工具层 - 全量
          'common.dart',
          'cgprivilege.dart',
          'shelf_proxy.dart',
          'log_utils.dart',
          'image_saver.dart',
          'agent_item.dart',
          'validate.dart',
          'ext.dart',
          'local_png.dart',
          'widget_utils.dart',
          'index.dart',

          // 上报与埋点
          'app_event_report.dart',
          'api_timing_interceptor.dart',
          'report_utils.dart',
          'page_request_tracker.dart',
          'router_observer.dart',
          'video_analytics_tracker.dart',
          'page_click_listener.dart',
          'report_search_click.dart',

          // Mixin
          'pay_mixin.dart',
          'nav_tab_bar_mixin.dart',

          // IM
          'shared.dart',
          'im.dart',
          'imdb.dart',

          // 上传
          'upload_resouce.dart',
          'start_upload.dart',

          // 核心页面入口
          'home.dart',
          'cg_webview.dart',
          'error_screen.dart',
        ];
      case 'hlw':
        return [
          // 网络与 API
          'network_http.dart',
          'request_api.dart',

          // 上报
          'event_report.dart',
          'global_click_reporter.dart',
          'report_timing_interceptor.dart',
          'report_timing_observer.dart',
          'report_banner_swiper.dart',
          'parent_meta_scope.dart',

          // 缓存与加解密
          'cache_manager.dart',
          'cache.dart',
          'image_decrypt.dart',
          'image_net_tool.dart',
          'image_load_async.dart',
          'encdecrypt.dart',

          // 全局状态与基础
          'base_store.dart',
          'index_page.dart',
          'startup_page.dart',
          'basewidget.dart',

          // 路由与工具
          'go_routers.dart',
          'utils.dart',
          'shelf_proxy.dart',
          'local_png.dart',
          'download_utils.dart',
          'approute_observer.dart',
          'preload_utils.dart',

          // mixin
          'pageviewmixin.dart',
          'nvideourl_minxin.dart',
          'page_cache_mixin.dart',

          // 入口
          'module_entry.dart',
          'main.dart',
        ];
      case 'tiktok':
        return [
          // 核心网络与 API
          'http.dart',
          'http_config.dart',
          'http_error.dart',
          'http_image.dart',
          'crypto_util.dart',
          'base_request.dart',
          'base_adapter.dart',
          'dio_adapter.dart',
          'res_adapter.dart',
          'log_util.dart',

          // 全局状态与路由
          'global.dart',
          'routes.dart',
          'line_detection_tool.dart',
          'bridge_provider_tool.dart',
          'splash_screen_page.dart',
          'splash_screen_mixin.dart',

          // module model 层
          'module_model_abs.dart',
          'module_model_config.dart',
          'module_model_user.dart',
          'module_model_video.dart',
          'module_model_tabs.dart',
          'video_player_model.dart',

          // 上报
          'report_request.dart',
          'report_interface.dart',
          'report_timing_interceptor.dart',
          'report_timing_observer.dart',
          'report_page_tracking.dart',
          'report_app_install.dart',
          'report_banner_tracking.dart',
          'report_nav_bar_tracking.dart',
          'report_search_tracking.dart',
          'report_order_tracking.dart',
          'app_route_observer.dart',

          // 上传
          'upload_manager.dart',
          'upload_helper.dart',
          'upload.dart',
          'upload_picker_mixin.dart',

          // 工具
          'default.dart',
          'various.dart',
          'nav_tab_bar.dart',
          'nav_tab_bar_mixin.dart',
          'download_video.dart',
          'preload_utils.dart',
          'widget_utils.dart',
          'history_record_tool.dart',

          // 入口
          'module_entry.dart',
          'main.dart',
        ];
      case '91cg':
        return [
          'network_http.dart', // HTTP 网络层
          'request_api.dart', // API 请求入口
          'app_event_report.dart', // 事件上报
          'cache_manager.dart', // 缓存管理
          'go_routers.dart', // 路由
          'utils.dart', // 工具类
          'encdecrypt.dart', // 加解密工具
          'module_entry.dart', // 模块入口
        ];
      case '51cg':
        return [
          // 网络与 API
          'network_http.dart',
          'request_api.dart',

          // 上报与路由观测
          'report_timing_interceptor.dart',
          'report_timing_observer.dart',
          'report_popup_alert.dart',
          'report_banner_swiper.dart',
          'analytics_reporter.dart',
          'report_gesture_detector.dart',
          'page_name.dart',
          'approute_observer.dart',

          // 缓存与加解密
          'cache_manager.dart',
          'cache.dart',
          'image_decrypt.dart',
          'image_net_tool.dart',
          'image_load_async.dart',
          'encdecrypt.dart',

          // 全局状态与基础页面
          'base_store.dart',
          'index_page.dart',
          'startup_page.dart',
          'basewidget.dart',
          'update_sysalert.dart',
          'custom_https_proxy.dart',
          'parent_meta_scope.dart',

          // 路由与工具
          'go_routers.dart',
          'utils.dart',
          'shelf_proxy.dart',
          'local_png.dart',
          'style_theme.dart',
          'platform_utils_native.dart',
          'platform_utils_web.dart',
          'eventbus_class.dart',
          'pull_refresh.dart',
          'load_status.dart',
          'watermark_util.dart',
          'watermark_util_io.dart',
          'watermark_util_web.dart',

          // mixin
          'pageviewmixin.dart',
          'nvideourl_minxin.dart',
          'page_cache_mixin.dart',

          // 主题与核心页面
          'change_theme_skin.dart',
          'home_page.dart',
          'community_page.dart',
          'keep_page.dart',
          'mine_page.dart',
          'welfare_page.dart',
          'sign_in_page.dart',
        ];
      case 'mrds':
        return [
          // 网络与 API
          'network_http.dart',
          'request_api.dart',
          'custom_https_proxy.dart',

          // 上报与路由观测
          'app_event_report.dart',
          'api_timing_interceptor.dart',
          'report_utils.dart',
          'page_request_tracker.dart',
          'router_observer.dart',
          'approute_observer.dart',
          'video_analytics_tracker.dart',
          'page_click_listener.dart',
          'report_search_click.dart',

          // 缓存与加解密
          'cache_manager.dart',
          'cache.dart',
          'image_decrypt.dart',
          'image_net_tool.dart',
          'image_load_async.dart',
          'encdecrypt.dart',

          // 全局状态与基础页面
          'base_store.dart',
          'user_status.dart',
          'index_page.dart',
          'startup_page.dart',
          'basewidget.dart',
          'update_sysalert.dart',

          // 路由与工具
          'go_routers.dart',
          'utils.dart',
          'shelf_proxy.dart',
          'local_png.dart',
          'style_theme.dart',
          'platform_utils_native.dart',
          'platform_utils_web.dart',
          'download_utils.dart',

          // mixin
          'pageviewmixin.dart',
          'nvideourl_minxin.dart',
          'page_cache_mixin.dart',
          'pull_refresh.dart',

          // 核心页面
          'home_page.dart',
          'home_content_page.dart',
          'home_content_detail_page.dart',
          'community_page.dart',
          'community_post_page.dart',
          'community_topic_detail_page.dart',
          'match_page.dart',
          'match_page_new.dart',
          'match_detail_page.dart',
          'mine_page.dart',
          'mine_login_page.dart',
          'ai_home_page.dart',
          'ai_face_page.dart',
          'ai_paint_page.dart',

          // 入口
          'module_entry.dart',
          'main.dart',
        ];
      case 'hlbdy':
        return [
          // 网络、选线与 API
          'network_http.dart',
          'request_api.dart',
          'shelf_proxy.dart',
          'line_check.dart',
          'secrets.dart',

          // 上报与路由观测
          'app_event_report.dart',
          'api_timing_interceptor.dart',
          'page_request_tracker.dart',
          'router_observer.dart',
          'approute_observer.dart',
          'video_analytics_tracker.dart',
          'page_click_listener.dart',
          'report_search_click.dart',
          'report_banner.dart',
          'report_feed_banner.dart',
          'report_utils.dart',
          'page_name.dart',

          // 缓存、图片与加解密
          'cache_manager.dart',
          'cache.dart',
          'cache.g.dart',
          'image_decrypt.dart',
          'image_net_tool.dart',
          'image_load_async.dart',
          'image_load_async_web.dart',
          'encdecrypt.dart',
          'security_guard.dart',

          // 全局状态与基础页面
          'base_store.dart',
          'user_status.dart',
          'index_page.dart',
          'startup_page.dart',
          'basewidget.dart',
          'update_sysalert.dart',
          'buoyant_ads_widget.dart',

          // 路由、资源与工具
          'go_routers.dart',
          'utils.dart',
          'local_png.dart',
          'style_theme.dart',
          'platform_utils_native.dart',
          'platform_utils_web.dart',
          'download_utils.dart',
          'media_picker.dart',
          'pull_refresh.dart',

          // mixin 与播放器
          'pageviewmixin.dart',
          'nvideourl_minxin.dart',
          'page_cache_mixin.dart',
          'player_lifecycle.dart',
          'short_mv_player.dart',
          'shortv_player.dart',

          // 核心页面
          'home_page.dart',
          'home_content_page.dart',
          'home_content_detail_page.dart',
          'home_player_page.dart',
          'home_search_page.dart',
          'community_page.dart',
          'community_main_page.dart',
          'community_post_page.dart',
          'community_post_detail_page.dart',
          'wanted_page.dart',
          'wanted_detail_page.dart',
          'video_page.dart',
          'video_detail_page.dart',
          'mine_page.dart',
          'mine_login_page.dart',
          'ai_main_page.dart',
          'ai_faceoff.dart',
          'ai_paint_page.dart',
          'ai_strip.dart',
          'ai_voice_page.dart',

          // 入口
          'module_entry.dart',
          'main.dart',
        ];
      case 'yms':
        return [
          // 核心网络层
          'client_api.dart',
          'net_manager.dart',
          'http_signature_interceptor.dart',
          'http_header_interceptor.dart',
          'http_resp_interceptor.dart',
          'safe_http_log_interceptor.dart',
          'api_exception.dart',
          'base_resp_bean.dart',
          'code.dart',
          'dio_slice_downloader.dart',

          // 配置与域名
          'address.dart',
          'config.dart',
          'share_key.dart',
          'detect_line_manager.dart',

          // 全局状态
          'store.dart',

          // 本地存储层
          'novel_record_store.dart',
          'episode_record_sotre.dart',
          'local_application_info_store.dart',
          'movie_record_sotre.dart',
          'cached_video_store.dart',
          'post_record_store.dart',
          'comics_record_store.dart',
          'local_ads_info_store.dart',

          // 任务 (上传/下载)
          'comic_download_task.dart',
          'comic_download_helper.dart',
          'video_upload_task.dart',
          'video_upload_helper.dart',
          'image_upload_task.dart',
          'image_upload_helper.dart',
          'multi_image_upload_task.dart',
          'multi_image_upload_helper.dart',
          'video_download_task.dart',
          'video_download_helper.dart',

          // 工具
          'app_util.dart',
          'utils.dart',
          'cache_util.dart',
          'install_check.dart',
          'dnsolve.dart',

          // 资源
          'pubspec.dart',
          'router_key.dart',

          // 入口
          'module_entry.dart',
          'main.dart',
          'app.dart',
        ];
      case 'oio':
        return [
          // 核心网络层
          'client_api.dart',
          'net_manager.dart',
          'http_signature_interceptor.dart',
          'http_header_interceptor.dart',
          'http_resp_interceptor.dart',
          'api_exception.dart',
          'base_resp_bean.dart',
          'code.dart',
          'dio_slice_downloader.dart',

          // 配置、域名与埋点
          'address.dart',
          'config.dart',
          'share_key.dart',
          'detect_line_manager.dart',
          'analytics_sdk_initializer.dart',
          'event_buried_manager.dart',
          'device_service.dart',
          'track_route.dart',
          'track_session_manager.dart',
          'track_uploader.dart',

          // 全局状态
          'store.dart',
          'bottom_trans_model.dart',
          'can_play_count_model.dart',
          'new_msg_model.dart',
          'rbtn_status_model.dart',
          'main_player_ui_show_model.dart',
          'second_player_ui_show_model.dart',

          // 本地存储层
          'm3u8_download_store.dart',
          'novel_record_store.dart',
          'episode_record_sotre.dart',
          'movie_record_sotre.dart',
          'cached_video_store.dart',
          'post_record_store.dart',
          'comics_record_store.dart',
          'photo_record_store.dart',
          'game_record_store.dart',
          'local_ads_info_store.dart',

          // 任务与工具
          'video_upload_task.dart',
          'video_upload_helper.dart',
          'video_download_task.dart',
          'video_download_helper.dart',
          'app_util.dart',
          'utils.dart',
          'cache_util.dart',
          'install_check.dart',
          'video_play_manage.dart',
          'video_preload_manager.dart',
          'player_util.dart',
          'dnsolve.dart',

          // 资源与路由
          'pubspec.dart',
          'router_key.dart',
          'router_map.dart',
          'jump_router.dart',

          // 入口
          'module_entry.dart',
          'main.dart',
          'app.dart',
        ];
      case 'bili':
        return [
          // 核心网络层
          'client_api.dart',
          'net_manager.dart',
          'http_signature_interceptor.dart',
          'http_header_interceptor.dart',
          'http_resp_interceptor.dart',
          'safe_http_log_interceptor.dart',
          'retry_interceptor.dart',
          'circuit_breaker.dart',
          'api_exception.dart',
          'base_resp_bean.dart',
          'code.dart',
          'dio_slice_downloader.dart',

          // 配置、域名、通知与埋点
          'address.dart',
          'config.dart',
          'share_key.dart',
          'detect_line_manager.dart',
          'local_notification.dart',
          'event_buried_manager.dart',
          'device_service.dart',
          'track_route.dart',
          'track_session_manager.dart',
          'track_uploader.dart',
          'track_event_storage.dart',
          'track_msg_reader.dart',
          'track_msg_video.dart',

          // 全局状态
          'store.dart',
          'vip_checker.dart',
          'bottom_trans_model.dart',
          'can_play_count_model.dart',
          'new_msg_model.dart',
          'rbtn_status_model.dart',

          // 本地存储层
          'm3u8_download_store.dart',
          'novel_record_store.dart',
          'novel_text_record_store.dart',
          'episode_record_sotre.dart',
          'movie_record_sotre.dart',
          'cached_video_store.dart',
          'post_record_store.dart',
          'comics_record_store.dart',
          'photo_record_store.dart',
          'game_record_store.dart',
          'local_ads_info_store.dart',

          // 任务与工具
          'video_upload_task.dart',
          'video_upload_helper.dart',
          'video_download_task.dart',
          'video_download_helper.dart',
          'image_upload_task.dart',
          'image_upload_helper.dart',
          'multi_image_upload_task.dart',
          'multi_image_upload_helper.dart',
          'app_util.dart',
          'utils.dart',
          'cache_util.dart',
          'install_check.dart',
          'video_play_manage.dart',
          'player_util.dart',

          // 资源与路由
          'pubspec.dart',
          'router_key.dart',
          'router_map.dart',
          'jump_router.dart',

          // 入口
          'module_entry.dart',
          'main.dart',
          'app.dart',
        ];
      case '91porn':
        return [
          // 入口与初始化
          'module_entry.dart',
          'main.dart',
          'config.dart',
          'address.dart',
          'store.dart',
          'local_ads_info_store.dart',

          // 网络、域名与响应层
          'http_manager.dart',
          'net_manager.dart',
          'http_response_interceptor.dart',
          'api_exception.dart',
          'base_resp_bean.dart',
          'net_code.dart',
          'detect_line_manager.dart',

          // API 服务层
          'vid_service.dart',
          'mine_service.dart',
          'common_service.dart',
          'ai_service.dart',
          'acg_service.dart',
          'comment_service.dart',
          'search_service.dart',
          'tag_service.dart',
          'actress_service.dart',
          'collection_service.dart',
          'group_service.dart',
          'find_service.dart',
          'pre_sale_service.dart',
          'live_service.dart',

          // 埋点与设备
          'track_uploader.dart',
          'track_session.dart',
          'track_manager.dart',
          'track_route.dart',
          'device_service.dart',

          // 下载、缓存与本地服务
          'video_download_manager.dart',
          'down_load_task.dart',
          'm3u8_download_utils.dart',
          'local_server.dart',
          'local_server_guard.dart',
          'video_cache_manager.dart',
          'cache_util.dart',
          'file_util.dart',
          'free_play_count_manager.dart',

          // 页面逻辑与路由
          'splash_logic.dart',
          'splash_page.dart',
          'main_logic.dart',
          'main_page.dart',
          'home_main_logic.dart',
          'home_main_page.dart',
          'short_video_main_logic.dart',
          'short_video_main_page.dart',
          'community_main_logic.dart',
          'community_main_page.dart',
          'live_main_logic.dart',
          'live_main_page.dart',
          'router_map.dart',
          'jump_router.dart',

          // 工具
          'install_util.dart',
          'version_util.dart',
          'crypto_utils.dart',
          'player_util.dart',
          'video_utils.dart',
          'dnsolve.dart',
        ];
      case '91porn2':
        return [
          // 入口与初始化
          'module_entry.dart',
          'main.dart',

          // 网络、域名与响应层
          'http_config.dart',
          'http_api.dart',
          'base_request.dart',
          'crypto_util.dart',
          'm3u8_normalizer.dart',
          'http.dart',
          'dio_adapter.dart',
          'res_adapter.dart',
          'http_error.dart',
          'state_mixin.dart',
          'refresh_load_list_widget.dart',
          'http_image.dart',

          // 全局配置、启动与路由
          'global.dart',
          'line_detection_tool.dart',
          'splash_screen_page.dart',
          'splash_screen_mixin.dart',
          'routes.dart',
          'module_model_config.dart',
          'module_model_user.dart',
          'bridge_provider_tool.dart',
          'stack_indexed_widget.dart',

          // 埋点、设备与页面映射
          'report_monitor_event.dart',
          'report_ads_event.dart',
          'report_nav_bar_tracking.dart',
          'report_video_event.dart',
          'router_page_key_name.dart',

          // 播放器、下载、缓存与支付
          'shelf_proxy.dart',
          'player_video_mixin.dart',
          'player_native_widget.dart',
          'player_webpage_widget.dart',
          'video_reporter.dart',
          'history_record_tool.dart',
          'download_video.dart',
          'pm_payment_mixin.dart',
          'online_timer_service.dart',

          // 工具
          'common.dart',
          'event_bus.dart',
          'web_util.dart',
        ];
      case 'txpjb':
        return [
          // 入口、路由与配置
          'module_entry.dart',
          'main.dart',
          'route_config.dart',
          'project_config.dart',

          // 网络、域名与原生桥
          'HostProvider.dart',
          'HostComicProvider.dart',
          'token_interceptor.dart',
          'analytics_utils.dart',
          'cdn_util.dart',
          'cdn_line.dart',
          'device_utils.dart',
          'jh_version_utils.dart',
          'file_utils.dart',
          'route.dart',
          'event_bus.dart',

          // 启动与首页
          'first_view.dart',
          'splash_logic.dart',
          'main_logic.dart',
          'home_logic.dart',
          'square_logic.dart',
          'mine_logic.dart',
          'setting_logic.dart',
          'hot_list_logic.dart',
          'questionnaire_logic.dart',
          'change_logo_logic.dart',

          // 视频、直播、动态与搜索
          'movie_detail_logic.dart',
          'play_video_logic.dart',
          'short_video_logic.dart',
          'short_video_list_logic.dart',
          'short_video_filter_logic.dart',
          'random_short_video_logic.dart',
          'stream_logic.dart',
          'stream_detail_logic.dart',
          'stream_user_logic.dart',
          'col_stream_logic.dart',
          'dynamic_detail_logic.dart',
          'release_dynamic_logic.dart',
          'up_dynamic_logic.dart',
          'up_dynamic_detail_logic.dart',
          'search_logic.dart',
          'search_result_logic.dart',

          // 用户、支付、任务与分享
          'user_center_logic.dart',
          'buy_coin_logic.dart',
          'become_vip_logic.dart',
          'coin_history_logic.dart',
          'vip_history_logic.dart',
          'task_logic.dart',
          'task_center_logic.dart',
          'shop_logic.dart',
          'shop_history_logic.dart',
          'sign_in_logic.dart',
          'share_logic.dart',
          'share_history_logic.dart',
          'bind_phone_logic.dart',
          'bind_invite_code_logic.dart',
          'check_phone_logic.dart',
          'set_password_logic.dart',
          'scan_q_r_code_logic.dart',
          'recommend_user_list_logic.dart',
          'comment_history_logic.dart',
          'history_col_buy_like_logic.dart',

          // AI、漫画、动漫、导航与活动
          'ai_all_list_logic.dart',
          'ai_detail_logic.dart',
          'ai_grid_main_logic.dart',
          'ai_list_logic.dart',
          'ai_main_logic.dart',
          'ai_pic_logic.dart',
          'ai_pic_to_video_logic.dart',
          'ai_pic_to_video_detail_logic.dart',
          'ai_clear_logic.dart',
          'ai_novel_logic.dart',
          'ai_novel_detail_logic.dart',
          'ai_girl_logic.dart',
          'smear_logic.dart',
          'ai_smear_detail_logic.dart',
          'comic_detail_logic.dart',
          'comic_chapter_detail_logic.dart',
          'read_comic_logic.dart',
          'cartoon_list_logic.dart',
          'anima_logic.dart',
          'anima_main_logic.dart',
          'lottery_logic.dart',
          'lottery_history_logic.dart',
          'app_center_logic.dart',
          'product_detail_logic.dart',
          'nude_chat_logic.dart',
          'nude_chat_detail_logic.dart',
        ];
      case 'xjpjb':
        return [
          // 入口、路由与配置
          'module_entry.dart',
          'main.dart',
          'route_config.dart',
          'project_config.dart',

          // 网络、域名与原生桥
          'HostProvider.dart',
          'HostComicProvider.dart',
          'token_interceptor.dart',
          'analytics_utils.dart',
          'cdn_util.dart',
          'device_utils.dart',
          'jh_version_utils.dart',
          'file_utils.dart',
          'route.dart',
          'event_bus.dart',

          // 启动与首页
          'first_view.dart',
          'splash_logic.dart',
          'main_logic.dart',
          'home_logic.dart',
          'square_logic.dart',
          'mine_logic.dart',
          'setting_logic.dart',

          // 视频、直播、动态与搜索
          'movie_logic.dart',
          'movie_detail_logic.dart',
          'play_video_logic.dart',
          'short_video_logic.dart',
          'short_video_list_logic.dart',
          'stream_logic.dart',
          'stream_detail_logic.dart',
          'stream_user_logic.dart',
          'dynamic_detail_logic.dart',
          'dynamic_category_detail_logic.dart',
          'release_dynamic_logic.dart',
          'up_dynamic_detail_logic.dart',
          'search_logic.dart',
          'search_result_logic.dart',

          // 用户、支付、任务、商城与分享
          'user_center_logic.dart',
          'col_user_logic.dart',
          'buy_coin_logic.dart',
          'become_vip_logic.dart',
          'coin_history_logic.dart',
          'vip_history_logic.dart',
          'pay_result_logic.dart',
          'pay_tips_logic.dart',
          'task_logic.dart',
          'task_center_logic.dart',
          'shop_logic.dart',
          'shop_history_logic.dart',
          'sign_logic.dart',
          'share_logic.dart',
          'share_history_logic.dart',
          'bind_phone_logic.dart',
          'bind_invite_code_logic.dart',
          'change_logo_logic.dart',

          // AI、漫画、动漫、导航与活动
          'ai_main_logic.dart',
          'ai_pic_logic.dart',
          'ai_pic_to_video_logic.dart',
          'ai_pic_to_video_detail_logic.dart',
          'ai_clear_logic.dart',
          'ai_detail_logic.dart',
          'ai_all_list_logic.dart',
          'ai_list_logic.dart',
          'smear_logic.dart',
          'ai_smear_detail_logic.dart',
          'comic_detail_logic.dart',
          'comic_chapter_detail_logic.dart',
          'read_comic_logic.dart',
          'anima_logic.dart',
          'mall_detail_logic.dart',
          'product_detail_logic.dart',
          'nude_chat_logic.dart',
          'nude_chat_detail_logic.dart',
          'scan_q_r_code_logic.dart',
          'app_center_logic.dart',
          'product_logic.dart',
          'store_logic.dart',
        ];
      case 'acfun':
        return [
          // 入口与初始化
          'module_entry.dart',
          'app_prepare.dart',
          'main.dart',

          // 服务层 - 全量
          'app_service.dart',
          'user_service.dart',
          'storage_service.dart',
          'im_service.dart',
          'im_quota_service.dart',

          // HTTP 服务层
          'api_settings.dart',
          'api_encrypt.dart',
          'api_crypto.dart',
          'api_code.dart',

          // API 接口 - 全量
          'api.dart',
          'api_sys.dart',
          'api_home.dart',
          'api_user.dart',
          'api_search.dart',
          'api_video.dart',
          'api_comic.dart',
          'api_novel.dart',
          'api_community.dart',
          'api_coterie.dart',
          'api_welfare.dart',
          'api_ai.dart',
          'api_ad.dart',
          'api_mine.dart',
          'api_file.dart',
          'api_cdn.dart',
          'api_information.dart',
          'api_activity.dart',
          'api_fixed.dart',
          'api_adult_game.dart',
          'api_news.dart',
          'api_region.dart',
          'api_bookshelf.dart',
          'api_im.dart',
          'api_dynamic.dart',
          'api_blogger.dart',

          // 路由 - 全量
          'app_pages.dart',
          'app_routes.dart',
          'app_routes_jump.dart',
          'route_model.dart',
          'route_stack_tracker.dart',
          'internal_jump_routes.dart',
          'routes_pages_anime.dart',
          'routes_pages_common.dart',
          'routes_pages_community.dart',
          'routes_pages_mine.dart',
          'routes_pages_novel.dart',
          'routes_pages_video.dart',

          // 配置
          'app_config.dart',
          'proxy_config.dart',
          'app_build_config.dart',

          // 公共工具
          'payment_utils.dart',
          'report_utils.dart',
          'app_utils.dart',
          'novel_text_decrypt.dart',
          'ad_jump.dart',
          'upload_utils.dart',
        ];
      case 'nnrj':
        return [
          // 入口与初始化
          'module_entry.dart',
          'main.dart',
          'app.dart',
          'app_prepare.dart',
          'app_build_config.dart',
          'asset_resolver.dart',

          // 路由与启动
          'routes.dart',
          'pages.dart',
          'page_jump.dart',
          'launch_page.dart',
          'launch_ad_page.dart',
          'launch_code_page.dart',

          // 环境、域名与全局服务
          'environment_service.dart',
          'domain_generator.dart',
          'proxy.dart',
          'check_domain_utils.dart',
          'storage_service.dart',
          'user_service.dart',
          'app_service.dart',
          'notice_service.dart',
          'im_service.dart',
          'im_storage_service.dart',

          // HTTP 服务层
          'http_service.dart',
          'api_service.dart',
          'api_const.dart',
          'api_code.dart',
          'api_request_interceptor.dart',
          'api_response_interceptor.dart',
          'api_error_interceptor.dart',
          'api_exception_handler.dart',
          'http_special_code_handler.dart',
          'api_decrypt.dart',
          'api_encrpt.dart',
          'api_response_transformer.dart',

          // API 接口
          'api.dart',
          'api_sys.dart',
          'api_user.dart',
          'api_video.dart',
          'api_short_player.dart',
          'api_ai.dart',
          'api_activity.dart',
          'api_deduct.dart',
          'api_mine.dart',
          'api_search.dart',
          'api_message.dart',
          'api_content.dart',
          'api_blogger.dart',
          'api_choice.dart',
          'login.dart',

          // 埋点与上报
          'report.dart',
          'routes_register.dart',
          'ad_report.dart',
          'tracker.dart',
          'track_batch_service.dart',
          'track_config.dart',
          'track_config_parser.dart',
          'track_crypto.dart',
          'track_headers.dart',
          'track_route_observer.dart',
          'video_watch_tracker.dart',

          // 视频、支付、下载、AI
          'main_controller.dart',
          'video_player_page_controller.dart',
          'video_player_http_service.dart',
          'video_player_data_service.dart',
          'common_video_play_controller.dart',
          'short_v_p_cell_controller.dart',
          'short_video_player_page_controller.dart',
          'play_center_dispatch.dart',
          'pay_view_controller.dart',
          'm3u8_downloader_manager.dart',
          'local_server.dart',
          'file_downloader.dart',
          'video_cache_manager.dart',
          'upload_video_manager.dart',
          'ai_record_page_controller.dart',
          'hookup_detail_controller.dart',
          'game_detail_page_controller.dart',
        ];
      case 'tx':
        return [
          'module_entry.dart', // 模块入口
          'main.dart', // B 面启动入口
          'request.dart', // 业务请求入口
          'http_request.dart', // 底层 HTTP 实现
          'app_api.dart', // 线路与 API 常量
          'routers.dart', // 路由入口
          'global_logic.dart', // 全局状态与 system/info
          'splash_logic.dart', // 启动检测与选线
          'encrypt_dynamic_util.dart', // 动态加解密
          'endecode_util.dart', // 编解码与缓存加密
          'websocket_util.dart', // WebSocket 通道
          'device_util.dart', // 设备标识与请求头
        ];
      case 'dq':
        // 斗球 xty：与源工程 /Users/t-yh/dqiu/lib 实际结构对齐（只按 basename 匹配）。
        // 覆盖全部基础设施层：网络/API/Service/Manager/加密/IM/路由/缓存/域名/启动。
        // 故意排除海量 UI（*_page/_widget/_dialog）、纯数据 *_entity/_response 与 *_logic
        // GetX 控制器——callstack 包装注入会增加调用深度，仅对基础设施层安全且有价值。
        return [
          // --- 启动 / 路由 / 入口 ---
          'module_entry.dart',
          'main.dart',
          'splash_page.dart',
          'app_pages.dart',
          'app_routes.dart',
          'config.dart',
          'view_config.dart',
          'bface_core_init.dart',
          // --- 网络 / HTTP ---
          'http_manager.dart',
          'http_utils.dart',
          'http_result_entity.dart',
          'mock_interceptor.dart',
          // --- API 层 ---
          'app_data_api.dart',
          'chat_api.dart',
          'collection_api.dart',
          'common_api.dart',
          'community_api.dart',
          'hw_api.dart',
          'im_api.dart',
          'login_api.dart',
          'match_api.dart',
          'match_data_api.dart',
          'match_detail_api.dart',
          'match_detail_esport_api.dart',
          'match_dj_api.dart',
          'match_esport_api.dart',
          'match_filter_api.dart',
          'material_api.dart',
          'mine_api.dart',
          'news_api.dart',
          'search_api.dart',
          'video_api.dart',
          'video_detail_api.dart',
          'video_gift_api.dart',
          // --- Service 层 ---
          'app_data_service.dart',
          'banner_service.dart',
          'chat_service.dart',
          'collection_service.dart',
          'common_service.dart',
          'community_service.dart',
          'hw_service.dart',
          'im_service.dart',
          'login_service.dart',
          'match_data_service.dart',
          'match_detail_esport_service.dart',
          'match_detail_service.dart',
          'match_dj_service.dart',
          'match_esport_service.dart',
          'match_filter_service.dart',
          'match_service.dart',
          'material_service.dart',
          'mine_service.dart',
          'news_service.dart',
          'news_video_service.dart',
          'search_service.dart',
          'video_detail_service.dart',
          'video_gift_service.dart',
          'video_service.dart',
          // --- Manager 层（数据/基础设施）---
          'app_data_manager.dart',
          'baseball_data_manager.dart',
          'basket_data_manager.dart',
          'esport_data_manager.dart',
          'foot_data_manager.dart',
          'tennis_data_manager.dart',
          'audio_manager.dart',
          'im_manager.dart',
          'log_manager.dart',
          'match_push_manager.dart',
          'player_set_manager.dart',
          'view_config_manager.dart',
          'event_bus_manager.dart',
          'xx_user_manager.dart',
          'xx_domain_manager.dart',
          'json_cache_manager.dart',
          // --- IM / socket ---
          'im_client.dart',
          'rongcloud_im_client.dart',
          'global_heart_beat.dart',
          // --- 加密 ---
          'encryption_utils.dart',
          'encrypt_strings.dart',
          'domain_encrypt_utils.dart',
          // --- 域名 / 全局 / 日志 / 缓存 / 存储 ---
          'global_logic.dart',
          'common_log.dart',
          'app_cache_utils.dart',
          'match_cache.dart',
          'material_cache_util.dart',
          'storage_keys.dart',
          'ServiceDataStorage.dart',
        ];
      case 'lgt':
        // 聊个天/IM：与 acfun 相同策略（服务层 + API 全量 + 路由）
        return _getAllCoreFiles('acfun');
      case 'douyin':
        return [
          'main.dart',
          'router.dart',
          'app_init.dart',
          'app_api.dart',
          'app_service.dart',
          'notification_service.dart',
          'http_api.dart',
          'http_upload.dart',
          'device_util.dart',
          'sp_util.dart',
          'event_bus.dart',
          'event_router_observer.dart',
          'aes_dynamic_util.dart',
          'websocket_util.dart',
          'login_api.dart',
          'system_api.dart',
          'search_api.dart',
          'user_api.dart',
          'movie_api.dart',
          'post_api.dart',
          'chat_api.dart',
          'comment_api.dart',
          'danmaku_api.dart',
          'platform_api.dart',
          'go.dart',
          'router_util.dart',
        ];
      default:
        return [
          'api_service.dart',
          'user_service.dart',
        ];
    }
  }

  /// 随机选择要处理的核心文件（增加随机性）
  List<String> _selectCoreFiles(String projectName) {
    final allFiles = _getAllCoreFiles(projectName);

    // 保证一些核心文件必须被混淆
    final requiredFiles = <String>[];
    switch (projectName) {
      case 'hjsq':
        requiredFiles.addAll([
          'base_service.dart',
          'account_service.dart',
          'repo.dart',
          'home_service.dart',
          'user_service.dart',
          'ai_service.dart',
          'http_interceptor.dart',
          'module_entry.dart',
          'app_global.dart',
          'crypto.dart',
          'cache.dart',
          'r2_uploader.dart',
          'cartoon_service.dart',
          'game_service.dart',
          'live_service.dart',
          'order_service.dart',
          'withdraw_service.dart',
          'proxy_service.dart',
        ]);
        break;
      case 'ph':
        requiredFiles.addAll(['api_service.dart', 'login.dart']);
        break;
      case '51pc':
        requiredFiles.addAll([
          'api.dart',
          'http.dart',
          'api_path.dart',
          'encdecrypt.dart',
          'local_crypto.dart',
          'app_global.dart',
          'global.dart',
          'module_entry.dart',
          'routers.dart',
          'common.dart',
          'cgprivilege.dart',
          'app_event_report.dart',
          'api_timing_interceptor.dart',
          'shelf_proxy.dart',
          'pay_mixin.dart',
          'shared.dart',
          'home.dart',
          'homeConfig.dart',
        ]);
        break;
      case 'hlw':
        requiredFiles.addAll([
          'network_http.dart',
          'request_api.dart',
          'module_entry.dart',
          'event_report.dart',
          'cache_manager.dart',
          'encdecrypt.dart',
          'base_store.dart',
          'go_routers.dart',
          'shelf_proxy.dart',
          'global_click_reporter.dart',
          'image_decrypt.dart',
        ]);
        break;
      case 'tiktok':
        requiredFiles.addAll([
          'http.dart',
          'crypto_util.dart',
          'global.dart',
          'http_config.dart',
          'routes.dart',
          'module_entry.dart',
          'line_detection_tool.dart',
          'bridge_provider_tool.dart',
          'report_request.dart',
          'report_interface.dart',
          'upload_manager.dart',
          'module_model_config.dart',
          'module_model_user.dart',
          'dio_adapter.dart',
        ]);
        break;
      case '91cg':
        requiredFiles.addAll([
          'network_http.dart',
          'request_api.dart',
          'module_entry.dart',
          'app_event_report.dart',
          'api_timing_interceptor.dart',
          'app_global_click_wrapper.dart',
          'page_click_listener.dart',
          'page_name.dart',
          'page_request_tracker.dart',
          'report_track.dart',
          'report_utils.dart',
          'router_observer.dart',
          'cache_manager.dart',
          'encdecrypt.dart',
          'base_store.dart',
          'go_routers.dart',
          'utils.dart',
          'local_png.dart',
          'index_page.dart',
          'startup_page.dart',
          'update_sysalert.dart',
          'shelf_proxy.dart',
        ]);
        break;
      case '51cg':
        requiredFiles.addAll([
          'network_http.dart',
          'request_api.dart',
          'module_entry.dart',
          'report_timing_interceptor.dart',
          'report_timing_observer.dart',
          'analytics_reporter.dart',
          'report_gesture_detector.dart',
          'page_name.dart',
          'cache_manager.dart',
          'encdecrypt.dart',
          'base_store.dart',
          'go_routers.dart',
          'utils.dart',
          'local_png.dart',
          'index_page.dart',
          'startup_page.dart',
          'update_sysalert.dart',
        ]);
        break;
      case 'mrds':
        requiredFiles.addAll([
          'network_http.dart',
          'request_api.dart',
          'module_entry.dart',
          'app_event_report.dart',
          'api_timing_interceptor.dart',
          'cache_manager.dart',
          'encdecrypt.dart',
          'base_store.dart',
          'user_status.dart',
          'go_routers.dart',
          'utils.dart',
          'local_png.dart',
          'index_page.dart',
          'startup_page.dart',
          'home_page.dart',
          'community_page.dart',
          'match_page.dart',
          'ai_home_page.dart',
        ]);
        break;
      case 'hlbdy':
        requiredFiles.addAll([
          'network_http.dart',
          'request_api.dart',
          'module_entry.dart',
          'app_event_report.dart',
          'api_timing_interceptor.dart',
          'cache_manager.dart',
          'encdecrypt.dart',
          'security_guard.dart',
          'base_store.dart',
          'user_status.dart',
          'go_routers.dart',
          'utils.dart',
          'local_png.dart',
          'index_page.dart',
          'startup_page.dart',
          'home_page.dart',
          'community_page.dart',
          'video_page.dart',
          'ai_main_page.dart',
          'mine_page.dart',
        ]);
        break;
      case 'yms':
        requiredFiles.addAll([
          'client_api.dart',
          'net_manager.dart',
          'http_signature_interceptor.dart',
          'http_header_interceptor.dart',
          'http_resp_interceptor.dart',
          'store.dart',
          'module_entry.dart',
          'address.dart',
          'config.dart',
          'app_util.dart',
          'comic_download_task.dart',
          'video_upload_task.dart',
          'dio_slice_downloader.dart',
        ]);
        break;
      case 'oio':
        requiredFiles.addAll([
          'client_api.dart',
          'net_manager.dart',
          'http_signature_interceptor.dart',
          'http_header_interceptor.dart',
          'http_resp_interceptor.dart',
          'store.dart',
          'module_entry.dart',
          'address.dart',
          'config.dart',
          'app_util.dart',
          'detect_line_manager.dart',
          'analytics_sdk_initializer.dart',
          'track_session_manager.dart',
          'track_uploader.dart',
          'video_upload_task.dart',
          'video_download_task.dart',
          'dio_slice_downloader.dart',
          'router_map.dart',
        ]);
        break;
      case 'bili':
        requiredFiles.addAll([
          'client_api.dart',
          'net_manager.dart',
          'http_signature_interceptor.dart',
          'http_header_interceptor.dart',
          'http_resp_interceptor.dart',
          'store.dart',
          'module_entry.dart',
          'address.dart',
          'config.dart',
          'app_util.dart',
          'detect_line_manager.dart',
          'local_notification.dart',
          'track_session_manager.dart',
          'track_uploader.dart',
          'track_event_storage.dart',
          'device_service.dart',
          'video_upload_task.dart',
          'video_download_task.dart',
          'image_upload_task.dart',
          'multi_image_upload_task.dart',
          'dio_slice_downloader.dart',
          'router_map.dart',
          'player_util.dart',
        ]);
        break;
      case '91porn':
        requiredFiles.addAll([
          'module_entry.dart',
          'main.dart',
          'http_manager.dart',
          'net_manager.dart',
          'detect_line_manager.dart',
          'vid_service.dart',
          'mine_service.dart',
          'common_service.dart',
          'splash_logic.dart',
          'track_uploader.dart',
          'track_session.dart',
          'device_service.dart',
          'store.dart',
          'router_map.dart',
          'jump_router.dart',
          'video_download_manager.dart',
        ]);
        break;
      case '91porn2':
        requiredFiles.addAll([
          'module_entry.dart',
          'main.dart',
          'global.dart',
          'routes.dart',
          'http_config.dart',
          'http_api.dart',
          'base_request.dart',
          'crypto_util.dart',
          'http.dart',
          'dio_adapter.dart',
          'splash_screen_page.dart',
          'line_detection_tool.dart',
          'report_monitor_event.dart',
          'report_video_event.dart',
          'shelf_proxy.dart',
          'player_video_mixin.dart',
        ]);
        break;
      case 'txpjb':
        requiredFiles.addAll([
          'module_entry.dart',
          'main.dart',
          'route_config.dart',
          'project_config.dart',
          'analytics_utils.dart',
          'token_interceptor.dart',
          'HostProvider.dart',
          'splash_logic.dart',
          'first_view.dart',
          'main_logic.dart',
          'home_logic.dart',
          'ai_main_logic.dart',
          'ai_pic_logic.dart',
          'ai_pic_to_video_logic.dart',
          'ai_clear_logic.dart',
          'task_logic.dart',
          'movie_detail_logic.dart',
          'play_video_logic.dart',
        ]);
        break;
      case 'xjpjb':
        requiredFiles.addAll([
          'module_entry.dart',
          'main.dart',
          'route_config.dart',
          'project_config.dart',
          'analytics_utils.dart',
          'token_interceptor.dart',
          'HostProvider.dart',
          'splash_logic.dart',
          'first_view.dart',
          'main_logic.dart',
          'home_logic.dart',
          'ai_main_logic.dart',
        ]);
        break;
      case 'acfun':
        requiredFiles.addAll([
          'module_entry.dart',
          'app_prepare.dart',
          'main.dart',
          'app_service.dart',
          'user_service.dart',
          'storage_service.dart',
          'im_service.dart',
          'im_quota_service.dart',
          'api_settings.dart',
          'api_encrypt.dart',
          'api_crypto.dart',
          'api.dart',
          'api_sys.dart',
          'api_home.dart',
          'api_user.dart',
          'api_video.dart',
          'api_comic.dart',
          'api_community.dart',
          'api_im.dart',
          'api_dynamic.dart',
          'api_blogger.dart',
          'app_pages.dart',
          'app_routes.dart',
          'routes_pages_anime.dart',
          'routes_pages_common.dart',
          'routes_pages_community.dart',
          'routes_pages_mine.dart',
          'routes_pages_novel.dart',
          'routes_pages_video.dart',
          'app_config.dart',
          'app_build_config.dart',
        ]);
        break;
      case 'nnrj':
        requiredFiles.addAll([
          'module_entry.dart',
          'main.dart',
          'app_prepare.dart',
          'app_build_config.dart',
          'routes.dart',
          'pages.dart',
          'launch_page.dart',
          'environment_service.dart',
          'storage_service.dart',
          'user_service.dart',
          'app_service.dart',
          'im_service.dart',
          'http_service.dart',
          'api_service.dart',
          'api_request_interceptor.dart',
          'api_response_interceptor.dart',
          'api.dart',
          'api_sys.dart',
          'api_user.dart',
          'api_video.dart',
          'api_ai.dart',
          'report.dart',
          'tracker.dart',
          'track_batch_service.dart',
          'video_player_page_controller.dart',
          'short_video_player_page_controller.dart',
        ]);
        break;
      case 'tx':
        requiredFiles.addAll([
          'module_entry.dart',
          'request.dart',
          'http_request.dart',
          'app_api.dart',
          'global_logic.dart',
          'splash_logic.dart',
        ]);
        break;
      case 'dq':
        requiredFiles.addAll([
          'module_entry.dart',
          'main.dart',
          'http_manager.dart',
          'global_logic.dart',
          'xx_domain_manager.dart',
        ]);
        break;
      case 'lgt':
        requiredFiles.addAll([
          'module_entry.dart', 'app_prepare.dart', 'main.dart',
          'app_service.dart', 'user_service.dart', 'storage_service.dart',
          'api_settings.dart', 'api_encrpt.dart', 'api_crypto.dart',
          'api.dart', 'api_sys.dart', 'api_home.dart', 'api_user.dart',
          'api_video.dart', 'app_pages.dart', 'app_routes.dart', 'app_config.dart',
        ]);
        break;
      case 'douyin':
        requiredFiles.addAll([
          'router.dart',
          'app_init.dart',
          'app_api.dart',
          'app_service.dart',
          'http_api.dart',
          'device_util.dart',
          'event_bus.dart',
          'login_api.dart',
          'system_api.dart',
          'user_api.dart',
          'movie_api.dart',
          'post_api.dart',
        ]);
        break;
      default:
        requiredFiles.addAll(['api_service.dart']);
    }

    // 从剩余文件中随机选择 85%-100%
    final optionalFiles =
        allFiles.where((f) => !requiredFiles.contains(f)).toList();
    final ratio = 0.85 + _random.nextDouble() * 0.15;
    final count = (optionalFiles.length * ratio).ceil();

    final shuffled = List<String>.from(optionalFiles)..shuffle(_random);
    final selected = shuffled.take(count).toList();

    return [...requiredFiles, ...selected];
  }

  /// Resolve the library key for a file.
  /// Files with `part of '...'` share their parent library's namespace.
  String _resolveLibraryKey(String filePath) {
    try {
      final lines = File(filePath).readAsLinesSync();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('//')) continue;
        final match = RegExp(r"^part\s+of\s+'([^']+)'\s*;").firstMatch(trimmed);
        if (match != null) {
          final partOfTarget = match.group(1)!;
          return path
              .normalize(path.join(path.dirname(filePath), partOfTarget));
        }
        break;
      }
    } catch (_) {}
    return path.normalize(filePath);
  }

  Future<void> process(
      List<String> files, AnalysisContextCollection collection) async {
    logger.step('调用栈混淆 (深度: ${config.callStackDepth})...');

    final projectName = config.projectName ?? 'default';

    // 随机选择核心文件（每次运行结果不同）
    final coreFiles = _selectCoreFiles(projectName);

    // 使用时间戳生成唯一种子（每次运行不同）
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final seed = '${projectName}_${timestamp % 10000}';

    var totalFiles = 0;
    var totalMethods = 0;

    // 筛选核心文件
    final targetFiles = files.where((f) {
      final fileName = path.basename(f);
      return coreFiles.any((core) => fileName == core);
    }).toList();

    if (targetFiles.isEmpty) {
      logger.warning('未找到核心文件，跳过调用栈混淆');
      logger.info('目标文件列表: ${coreFiles.join(", ")}');
      return;
    }

    logger.info('随机选择 ${coreFiles.length} 个核心文件: ${coreFiles.join(", ")}');
    logger.info('找到 ${targetFiles.length} 个匹配文件');

    // Track used class names per library to avoid duplicates in part-of files
    final usedClassNamesPerLibrary = <String, Set<String>>{};

    for (final file in targetFiles) {
      try {
        final context = collection.contextFor(file);
        final result = await context.currentSession.getResolvedUnit(file);

        if (result is! ResolvedUnitResult) {
          continue;
        }

        // 收集可混淆的方法
        final visitor = _MethodCollector();
        result.unit.accept(visitor);

        if (visitor.methods.isEmpty) {
          continue;
        }

        if (config.dryRun) {
          totalFiles++;
          totalMethods += visitor.methods.length;
          logger.debug(
              '[DRY-RUN] ${path.basename(file)}: ${visitor.methods.length} 个方法');
          continue;
        }

        // 读取文件内容
        final content = File(file).readAsStringSync();
        var newContent = content;

        // Resolve the library this file belongs to (handles part-of)
        final libraryKey = _resolveLibraryKey(file);
        final usedNames =
            usedClassNamesPerLibrary.putIfAbsent(libraryKey, () => {});

        // Generate a unique wrapper class name, retrying on collision
        String wrapperClassName;
        var attempt = 0;
        do {
          final randomSuffix = _random.nextInt(100000);
          wrapperClassName = NameGenerator.generateClassName(
              '${seed}_${path.basenameWithoutExtension(file)}_${randomSuffix}_$attempt');
          attempt++;
        } while (usedNames.contains(wrapperClassName) && attempt < 100);
        usedNames.add(wrapperClassName);

        // 随机选择方法名前缀
        final prefixes = ['wrap', 'proc', 'exec', 'run', 'call', 'invoke'];
        final prefix = prefixes[_random.nextInt(prefixes.length)];
        final asyncPrefix =
            'a${prefix.substring(0, 1).toUpperCase()}${prefix.substring(1)}';

        // 在文件末尾添加包装器类
        final wrapperClass = _generateWrapperClassWithPrefix(
            wrapperClassName, config.callStackDepth, prefix, asyncPrefix);

        // 随机选择部分方法进行混淆（避免全部混淆导致模式过于明显）
        final methodsToWrap = _selectMethodsToWrap(visitor.methods);

        // 从后向前处理，避免偏移量变化
        methodsToWrap.sort((a, b) => b.bodyOffset.compareTo(a.bodyOffset));

        for (final method in methodsToWrap) {
          // 随机选择包装深度
          final depth = _random.nextInt(config.callStackDepth) + 1;

          // 包装方法体（使用对应的前缀）
          newContent = _wrapMethodWithPrefix(
              newContent, method, wrapperClassName, prefix, asyncPrefix, depth);
        }

        // 添加包装器类
        if (methodsToWrap.isNotEmpty) {
          newContent = '$newContent\n$wrapperClass';
        }

        if (newContent != content) {
          File(file).writeAsStringSync(newContent);
          totalFiles++;
          totalMethods += methodsToWrap.length;
          logger
              .debug('混淆 ${methodsToWrap.length} 个方法: ${path.basename(file)}');
        }
      } catch (e) {
        logger.debug('跳过文件 ${path.basename(file)}: $e');
      }
    }

    if (config.dryRun) {
      logger.info('[DRY-RUN] 将处理 $totalFiles 个文件，$totalMethods 个方法');
    } else {
      logger.success('调用栈混淆完成: $totalFiles 个文件, $totalMethods 个方法');
    }
  }

  /// 生成包装器类（使用指定的方法名前缀）
  String _generateWrapperClassWithPrefix(
      String className, int depth, String prefix, String asyncPrefix) {
    final buffer = StringBuffer();

    // 随机选择注释风格
    final comments = [
      '/// Data processing helper',
      '/// Internal utility class',
      '/// State management helper',
      '/// Cache processing utility',
      '/// Event handler wrapper',
      '/// Request dispatcher utility',
      '/// Service invoker helper',
    ];
    buffer.writeln('\n${comments[_random.nextInt(comments.length)]}');
    buffer.writeln('class $className {');
    buffer.writeln('  $className._();');

    // 生成嵌套包装方法
    for (var i = 1; i <= depth; i++) {
      if (i == 1) {
        buffer.writeln('  static T $prefix$i<T>(T Function() fn) => fn();');
      } else {
        buffer.writeln(
            '  static T $prefix$i<T>(T Function() fn) => $prefix${i - 1}(fn);');
      }
    }

    // 生成异步版本
    for (var i = 1; i <= depth; i++) {
      if (i == 1) {
        buffer.writeln(
            '  static Future<T> $asyncPrefix$i<T>(Future<T> Function() fn) => fn();');
      } else {
        buffer.writeln(
            '  static Future<T> $asyncPrefix$i<T>(Future<T> Function() fn) => $asyncPrefix${i - 1}(fn);');
      }
    }

    buffer.writeln('}');
    return buffer.toString();
  }

  /// 随机选择部分方法进行混淆
  List<_MethodInfo> _selectMethodsToWrap(List<_MethodInfo> methods) {
    // 混淆 70%-95% 的方法
    final ratio = 0.7 + _random.nextDouble() * 0.25;
    final count = (methods.length * ratio).ceil().clamp(1, methods.length);

    final shuffled = List<_MethodInfo>.from(methods)..shuffle(_random);
    return shuffled.take(count).toList();
  }

  /// 包装方法体（使用指定的前缀）
  String _wrapMethodWithPrefix(String content, _MethodInfo method,
      String wrapperClass, String prefix, String asyncPrefix, int depth) {
    // 找到方法体的 { 位置
    final bodyStart = method.bodyOffset;
    final bodyContent = content.substring(bodyStart);

    // 查找方法体结束的 }（需要跳过字符串和注释中的大括号）
    final bodyEnd = _findMatchingBrace(bodyContent, bodyStart);

    if (bodyEnd == -1) return content;

    // 获取方法体内容（不包括 { }）
    final innerBody = content.substring(bodyStart + 1, bodyEnd).trim();

    // 如果方法体太简单（如空方法或单行），跳过
    if (innerBody.isEmpty || !innerBody.contains(';')) {
      return content;
    }

    final indentedInnerBody = _indentBlock(innerBody, '    ');

    String newBody;
    if (method.isAsync) {
      // 对于 async 方法：
      // 原: AsyncJson foo() async { ... return x; }
      //
      // 需要变成（移除 async，让包装器返回 Future）:
      // AsyncJson foo() { return wrapper.aExec<InnerType>(() async { ... return x; }); }
      //
      // method.returnType 已经是 Future 的内部类型（如 Map<String, dynamic>）

      // 移除方法签名中的 async 关键字
      final beforeBody = content.substring(0, bodyStart);

      // 查找 async 关键字（可能后面有空格）
      final asyncPattern = RegExp(r'\basync\s*$');
      final trimmedBefore = beforeBody.trimRight();
      final asyncMatch = asyncPattern.firstMatch(trimmedBefore);

      if (asyncMatch != null) {
        // 移除 async 关键字
        final beforeAsync = trimmedBefore.substring(0, asyncMatch.start);
        newBody = ' {\n'
            '  return $wrapperClass.$asyncPrefix$depth<${method.returnType}>(() async {\n'
            '$indentedInnerBody\n'
            '  });\n'
            '}';
        return beforeAsync + newBody + content.substring(bodyEnd + 1);
      } else {
        // 尝试更宽松的匹配：查找任意位置的 async
        final looseMatch = RegExp(r'\basync\b\s*').firstMatch(
            beforeBody.substring(
                beforeBody.length - 20 < 0 ? 0 : beforeBody.length - 20));
        if (looseMatch != null) {
          final searchStart =
              beforeBody.length - 20 < 0 ? 0 : beforeBody.length - 20;
          final matchStart = searchStart + looseMatch.start;
          final beforeAsync = content.substring(0, matchStart);
          final afterAsync = content.substring(
              matchStart + looseMatch.end - looseMatch.start, bodyStart);
          newBody = '{\n'
              '  return $wrapperClass.$asyncPrefix$depth<${method.returnType}>(() async {\n'
              '$indentedInnerBody\n'
              '  });\n'
              '}';
          return beforeAsync +
              afterAsync +
              newBody +
              content.substring(bodyEnd + 1);
        }
        // 无法找到 async，跳过该方法
        return content;
      }
    } else {
      newBody = '{\n'
          '  return $wrapperClass.$prefix$depth<${method.returnType}>(() {\n'
          '$indentedInnerBody\n'
          '  });\n'
          '}';
    }

    return content.substring(0, bodyStart) +
        newBody +
        content.substring(bodyEnd + 1);
  }

  String _indentBlock(String body, String indent) {
    return body
        .split('\n')
        .map((line) => line.isEmpty ? line : '$indent$line')
        .join('\n');
  }

  /// 查找匹配的右大括号，正确处理字符串和注释
  int _findMatchingBrace(String bodyContent, int bodyStart) {
    var braceCount = 0;
    var i = 0;

    while (i < bodyContent.length) {
      final char = bodyContent[i];

      // 跳过单行注释
      if (char == '/' &&
          i + 1 < bodyContent.length &&
          bodyContent[i + 1] == '/') {
        i += 2;
        while (i < bodyContent.length && bodyContent[i] != '\n') {
          i++;
        }
        continue;
      }

      // 跳过多行注释
      if (char == '/' &&
          i + 1 < bodyContent.length &&
          bodyContent[i + 1] == '*') {
        i += 2;
        while (i + 1 < bodyContent.length &&
            !(bodyContent[i] == '*' && bodyContent[i + 1] == '/')) {
          i++;
        }
        i += 2; // 跳过 */
        continue;
      }

      // 跳过原始字符串 r'...' 或 r"..."
      if (char == 'r' &&
          i + 1 < bodyContent.length &&
          (bodyContent[i + 1] == '"' || bodyContent[i + 1] == "'")) {
        final quote = bodyContent[i + 1];
        i += 2;
        while (i < bodyContent.length && bodyContent[i] != quote) {
          if (bodyContent[i] == '\\' && i + 1 < bodyContent.length) {
            i += 2; // 跳过转义
          } else {
            i++;
          }
        }
        i++; // 跳过结束引号
        continue;
      }

      // 跳过三引号字符串 ''' 或 """
      if ((char == '"' || char == "'") &&
          i + 2 < bodyContent.length &&
          bodyContent[i + 1] == char &&
          bodyContent[i + 2] == char) {
        final quote = char;
        i += 3;
        while (i + 2 < bodyContent.length &&
            !(bodyContent[i] == quote &&
                bodyContent[i + 1] == quote &&
                bodyContent[i + 2] == quote)) {
          i++;
        }
        i += 3; // 跳过结束三引号
        continue;
      }

      // 跳过普通字符串 '...' 或 "..."
      if (char == '"' || char == "'") {
        final quote = char;
        i++;
        while (i < bodyContent.length && bodyContent[i] != quote) {
          if (bodyContent[i] == '\\' && i + 1 < bodyContent.length) {
            i += 2; // 跳过转义字符
          } else {
            i++;
          }
        }
        i++; // 跳过结束引号
        continue;
      }

      // 计算大括号
      if (char == '{') braceCount++;
      if (char == '}') braceCount--;

      if (braceCount == 0) {
        return bodyStart + i;
      }

      i++;
    }

    return -1;
  }
}

/// 方法信息
class _MethodInfo {
  final String name;
  final int bodyOffset; // 方法体 { 的偏移量
  final bool isAsync; // 是否是 async 方法
  final String returnType; // 返回类型（对于 async 方法，是 Future 内部的类型）
  final String rawReturnType; // 原始返回类型

  _MethodInfo(this.name, this.bodyOffset, this.isAsync, this.returnType,
      this.rawReturnType);
}

/// 方法收集器
class _MethodCollector extends RecursiveAstVisitor<void> {
  final List<_MethodInfo> methods = [];

  // 常见的 Future 类型别名映射
  static const _futureTypeAliases = {
    'AsyncJson': 'Map<String, dynamic>',
    'AsyncResult': 'Result',
    'AsyncVoid': 'void',
  };

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    // 跳过 getter/setter
    if (node.isGetter || node.isSetter) {
      return;
    }

    // 跳过抽象方法
    if (node.isAbstract) {
      return;
    }

    final body = node.body;

    // 只处理块方法体（有 { } 的）
    if (body is! BlockFunctionBody) {
      return;
    }

    // 包装进闭包后，被重新赋值的可空参数会丧失 null promotion，跳过此类方法
    if (_hasReassignedNullableParams(node.parameters, body)) {
      return;
    }

    final isAsync = body.keyword?.lexeme == 'async';
    final rawType = _getRawReturnType(node);
    final returnType = _getInnerTypeForAsync(rawType, isAsync);

    // 跳过 dynamic 返回类型
    if (returnType == 'dynamic') {
      return;
    }

    // 对于 void：
    // - 同步 void 方法跳过（无法用 return 包装）
    // - 异步 Future<void> 可以包装（返回的是 Future）
    if (returnType == 'void' && !isAsync) {
      return;
    }

    methods.add(_MethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      isAsync,
      returnType,
      rawType,
    ));

    super.visitMethodDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    // 处理顶层函数（如 login()）
    final body = node.functionExpression.body;

    if (body is! BlockFunctionBody) {
      return;
    }

    // 包装进闭包后，被重新赋值的可空参数会丧失 null promotion，跳过此类方法
    if (_hasReassignedNullableParams(
        node.functionExpression.parameters, body)) {
      return;
    }

    final isAsync = body.keyword?.lexeme == 'async';
    final rawType = _getTopLevelRawReturnType(node);
    final returnType = _getInnerTypeForAsync(rawType, isAsync);

    // 跳过 dynamic 返回类型
    if (returnType == 'dynamic') {
      return;
    }

    // 对于 void：同步跳过，异步 Future<void> 可以包装
    if (returnType == 'void' && !isAsync) {
      return;
    }

    methods.add(_MethodInfo(
      node.name.lexeme,
      body.block.leftBracket.offset,
      isAsync,
      returnType,
      rawType,
    ));

    super.visitFunctionDeclaration(node);
  }

  /// 检测方法是否有可空参数在方法体中被重新赋值。
  /// 闭包捕获的变量如果在闭包内被赋值，Dart 不再对其做 null promotion。
  bool _hasReassignedNullableParams(
      FormalParameterList? params, FunctionBody body) {
    if (params == null) return false;
    if (body is! BlockFunctionBody) return false;

    final nullableNames = <String>{};
    for (final param in params.parameters) {
      final typeSource = _getParamTypeSource(param);
      final name = param.name?.lexeme;
      if (typeSource != null && typeSource.endsWith('?') && name != null) {
        nullableNames.add(name);
      }
    }
    if (nullableNames.isEmpty) return false;

    final checker = _NullableParamReassignmentChecker(nullableNames);
    body.accept(checker);
    return checker.hasReassignment;
  }

  String? _getParamTypeSource(FormalParameter param) {
    if (param is DefaultFormalParameter) {
      return _getParamTypeSource(param.parameter);
    }
    if (param is SimpleFormalParameter) {
      return param.type?.toSource();
    }
    return null;
  }

  /// 获取原始返回类型字符串
  String _getRawReturnType(MethodDeclaration node) {
    final returnType = node.returnType;
    if (returnType == null) return 'dynamic';
    return returnType.toSource();
  }

  String _getTopLevelRawReturnType(FunctionDeclaration node) {
    final returnType = node.returnType;
    if (returnType == null) return 'dynamic';
    return returnType.toSource();
  }

  /// 对于 async 方法，获取 Future 内部的类型
  ///
  /// - `Future<T>` -> `T`
  /// - `AsyncJson` (typedef Future<Map<...>>) -> `Map<String, dynamic>`
  /// - `T` (非 Future) -> `T`
  String _getInnerTypeForAsync(String rawType, bool isAsync) {
    if (!isAsync) {
      return rawType;
    }

    // 处理 Future<T>
    if (rawType.startsWith('Future<') && rawType.endsWith('>')) {
      final inner = rawType.substring(7, rawType.length - 1);
      return inner.isEmpty ? 'dynamic' : inner;
    }

    // 处理常见类型别名
    if (_futureTypeAliases.containsKey(rawType)) {
      return _futureTypeAliases[rawType]!;
    }

    // 对于其他类型别名，返回 dynamic 以保证安全
    // 这些可能是 typedef Future<...> 的别名
    return 'dynamic';
  }
}

/// 检测可空参数是否在方法体内被重新赋值
class _NullableParamReassignmentChecker extends RecursiveAstVisitor<void> {
  final Set<String> nullableParamNames;
  bool hasReassignment = false;

  _NullableParamReassignmentChecker(this.nullableParamNames);

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (node.leftHandSide is SimpleIdentifier) {
      final name = (node.leftHandSide as SimpleIdentifier).name;
      if (nullableParamNames.contains(name)) {
        hasReassignment = true;
      }
    }
    super.visitAssignmentExpression(node);
  }
}
