import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../config/env_config.dart';
import '../router/app_router.dart';
import '../services/config_service.dart';
import '../services/domain_manager.dart';

/// 开发者选项悬浮按钮
/// 显示应用信息、环境配置、远程配置等开发者信息
class EnvFloatingIndicator extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState>? navigatorKey;

  const EnvFloatingIndicator({
    super.key,
    required this.child,
    this.navigatorKey,
  });

  @override
  State<EnvFloatingIndicator> createState() => _EnvFloatingIndicatorState();
}

class _EnvFloatingIndicatorState extends State<EnvFloatingIndicator> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _packageInfo = info);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 非调试模式直接返回子组件
    if (!kDebugMode) {
      return widget.child;
    }

    return Stack(
      children: [
        widget.child,
        Positioned(
          right: 16,
          bottom: 100,
          child: _buildFloatingButton(),
        ),
      ],
    );
  }

  Widget _buildFloatingButton() {
    final configService = ConfigService();
    final isSecondary = configService.isSecondaryMode;

    return GestureDetector(
      onTap: _showDevOptions,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: EnvConfig.isTest ? Colors.orange : Colors.green,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Icon(
              Icons.developer_mode,
              color: Colors.white,
              size: 24,
            ),
            // 显示 A/B 面小标签
            Positioned(
              right: -6,
              top: -6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: isSecondary ? Colors.purple : Colors.blue,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isSecondary ? 'B' : 'A',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDevOptions() {
    final navContext = widget.navigatorKey?.currentContext;
    if (navContext == null) return;

    showModalBottomSheet(
      context: navContext,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _DevOptionsSheet(
        packageInfo: _packageInfo,
        navigatorKey: widget.navigatorKey,
        onEnvChanged: () => setState(() {}),
      ),
    );
  }
}

/// 开发者选项面板
class _DevOptionsSheet extends StatefulWidget {
  final PackageInfo? packageInfo;
  final GlobalKey<NavigatorState>? navigatorKey;
  final VoidCallback onEnvChanged;

  const _DevOptionsSheet({
    required this.packageInfo,
    this.navigatorKey,
    required this.onEnvChanged,
  });

  @override
  State<_DevOptionsSheet> createState() => _DevOptionsSheetState();
}

class _DevOptionsSheetState extends State<_DevOptionsSheet> {
  final ConfigService _configService = ConfigService();
  final DomainManager _domainManager = DomainManager();

  void _navigateToMode(FeatureMode mode) {
    final navContext = widget.navigatorKey?.currentContext;
    if (navContext != null) {
      AppRouter.navigateToMode(navContext, mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          _buildHeader(),
          const Divider(height: 1),
          // 内容区（可滚动）
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionTitle('应用信息'),
                  const SizedBox(height: 8),
                  _buildAppInfoSection(),
                  const SizedBox(height: 20),
                  _buildSectionTitle('网络环境'),
                  const SizedBox(height: 8),
                  _buildEnvSection(),
                  const SizedBox(height: 20),
                  _buildSectionTitle('远程配置'),
                  const SizedBox(height: 8),
                  _buildRemoteConfigSection(),
                  const SizedBox(height: 20),
                  _buildSectionTitle('域名管理'),
                  const SizedBox(height: 8),
                  _buildDomainManagerSection(),
                ],
              ),
            ),
          ),
          // 底部安全区
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.developer_mode, color: Colors.grey[700]),
          const SizedBox(width: 8),
          const Text(
            '开发者选项',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Colors.grey[800],
      ),
    );
  }

  Widget _buildAppInfoSection() {
    final info = widget.packageInfo;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          _buildInfoTile(
            icon: Icons.apps,
            label: '应用名称',
            value: info?.appName ?? '-',
          ),
          const SizedBox(height: 8),
          _buildInfoTile(
            icon: Icons.fingerprint,
            label: 'Bundle ID',
            value: info?.packageName ?? '-',
            canCopy: true,
          ),
          const SizedBox(height: 8),
          _buildInfoTile(
            icon: Icons.info_outline,
            label: '版本号',
            value: info != null ? '${info.version} (${info.buildNumber})' : '-',
          ),
        ],
      ),
    );
  }

  Widget _buildEnvSection() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // 当前环境
          Row(
            children: [
              Icon(
                EnvConfig.isTest ? Icons.science : Icons.verified,
                color: EnvConfig.isTest ? Colors.orange : Colors.green,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '当前环境',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    Text(
                      EnvConfig.envDisplayName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: EnvConfig.isTest ? Colors.orange : Colors.green,
                      ),
                    ),
                  ],
                ),
              ),
              // 切换按钮
              _buildEnvToggle(),
            ],
          ),
          const Divider(height: 16),
          // API 地址
          _buildInfoTile(
            icon: Icons.link,
            label: 'API 地址',
            value: EnvConfig.apiBaseUrl,
            canCopy: true,
            valueFontSize: 12,
          ),
        ],
      ),
    );
  }

  Widget _buildEnvToggle() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildEnvButton(
          label: '测试',
          isSelected: EnvConfig.isTest,
          color: Colors.orange,
          onTap: () async {
            if (!EnvConfig.isTest) {
              await EnvConfig.switchToTest();
              setState(() {});
              widget.onEnvChanged();
            }
          },
        ),
        const SizedBox(width: 4),
        _buildEnvButton(
          label: '正式',
          isSelected: EnvConfig.isProduction,
          color: Colors.green,
          onTap: () async {
            if (!EnvConfig.isProduction) {
              await EnvConfig.switchToProduction();
              setState(() {});
              widget.onEnvChanged();
            }
          },
        ),
      ],
    );
  }

  Widget _buildEnvButton({
    required String label,
    required bool isSelected,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.grey[300],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : Colors.grey[600],
          ),
        ),
      ),
    );
  }

  Widget _buildRemoteConfigSection() {
    final isSecondary = _configService.isSecondaryMode;
    final isMemoryMode = _configService.isMemoryModeEnabled;
    final isInSilentPeriod = _configService.isInSilentPeriod;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // 当前配置
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: isSecondary ? Colors.purple : Colors.blue,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  isSecondary ? 'B 面' : 'A 面',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isSecondary ? '次要模式' : '主要模式',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (isMemoryMode)
                      Text(
                        '已记忆 (永久)',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (isInSilentPeriod)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber[100],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.timer, size: 14, color: Colors.amber[800]),
                      const SizedBox(width: 4),
                      Text(
                        '静默期 (${_configService.silentPeriodRemainingDays.toStringAsFixed(1)} 天)',
                        style: TextStyle(fontSize: 12, color: Colors.amber[800]),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              Text(
                '跳过静默期',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
              const SizedBox(width: 4),
              SizedBox(
                height: 24,
                child: Switch(
                  value: _configService.skipSilentPeriodCheck,
                  onChanged: (value) {
                    setState(() {
                      _configService.skipSilentPeriodCheck = value;
                    });
                  },
                  activeColor: Colors.orange,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          // 调试操作
          Row(
            children: [
              Expanded(
                child: _buildDebugButton(
                  label: '切换 A 面',
                  icon: Icons.looks_one,
                  color: Colors.blue,
                  onTap: () async {
                    await _configService.debugResetMemoryMode();
                    Navigator.pop(context);
                    _navigateToMode(FeatureMode.primary);
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDebugButton(
                  label: '切换 B 面',
                  icon: Icons.looks_two,
                  color: Colors.purple,
                  onTap: () async {
                    await _configService.switchToSecondary();
                    Navigator.pop(context);
                    _navigateToMode(FeatureMode.secondary);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDomainManagerSection() {
    final dm = _domainManager;
    final cached = dm.cachedWorkingDomain;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildInfoTile(
            icon: Icons.dns,
            label: '当前工作域名',
            value: dm.currentWorkingDomain,
            canCopy: true,
            valueFontSize: 11,
          ),
          const SizedBox(height: 6),
          _buildInfoTile(
            icon: Icons.cached,
            label: '缓存域名',
            value: cached ?? '无',
            valueFontSize: 11,
          ),
          const SizedBox(height: 6),
          _buildInfoTile(
            icon: Icons.home,
            label: '默认域名',
            value: dm.defaultDomain,
            valueFontSize: 11,
          ),
          const SizedBox(height: 6),
          _buildInfoTile(
            icon: Icons.cloud,
            label: '域名列表缓存',
            value: dm.cacheStatusDescription,
            valueFontSize: 11,
          ),
          const Divider(height: 16),
          // 调试开关
          Row(
            children: [
              Expanded(
                child: Text(
                  '强制默认域名失败',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ),
              SizedBox(
                height: 24,
                child: Switch(
                  value: dm.debugForceFailDefault,
                  onChanged: (value) {
                    setState(() {
                      dm.debugForceFailDefault = value;
                    });
                  },
                  activeTrackColor: Colors.red[200],
                  // activeThumbColor: Colors.red,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '强制全部域名失败',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ),
              SizedBox(
                height: 24,
                child: Switch(
                  value: dm.debugForceFailAll,
                  onChanged: (value) {
                    setState(() {
                      dm.debugForceFailAll = value;
                    });
                  },
                  activeTrackColor: Colors.red[200],
                  // activeThumbColor: Colors.red,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const Divider(height: 16),
          // 操作按钮
          Row(
            children: [
              Expanded(
                child: _buildDebugButton(
                  label: '清除缓存域名',
                  icon: Icons.delete_outline,
                  color: Colors.orange,
                  onTap: () async {
                    await dm.clearCachedDomain();
                    await dm.clearDomainListCache();
                    setState(() {});
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildDebugButton(
                  label: '测试 Fallback',
                  icon: Icons.refresh,
                  color: Colors.teal,
                  onTap: () async {
                    dm.clearLog();
                    await _configService.refresh();
                    setState(() {});
                  },
                ),
              ),
            ],
          ),
          // Fallback 日志
          if (dm.fallbackLog.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(maxHeight: 160),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: Text(
                  dm.fallbackLog.join('\n'),
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'Courier',
                    color: Colors.greenAccent,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDebugButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String label,
    required String value,
    bool canCopy = false,
    double valueFontSize = 14,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
              Text(
                value,
                style: TextStyle(
                  fontSize: valueFontSize,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (canCopy)
          GestureDetector(
            onTap: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('已复制: $value'),
                  duration: const Duration(seconds: 1),
                ),
              );
            },
            child: Icon(Icons.copy, size: 16, color: Colors.grey[500]),
          ),
      ],
    );
  }
}
