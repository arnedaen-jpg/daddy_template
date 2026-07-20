import 'dart:convert';

/// CDN 类型 base64（与 XMSport / dqiu 一致）
const domainCdnA = 'YWxpeXVu'; // aliyun
const domainCdnT = 'dGVuY2VudA=='; // tencent
const domainCdnH = 'aHc='; // hw
const domainCdnF = 'ZnVubnVsbA=='; // funnull

/// 域名实体（对齐 XMSport XMDomain / dqiu XXDomainEntity）
///
/// `domain` 字段与硬编码兜底一致：持久化 / 拉源 JSON 使用 base64 映射，
/// 内存中始终为明文 URL（`https://...`）。
class DomainEntity {
  String domain;
  String token;
  String cdn;
  bool openFlag;
  int weight;
  int weightCnt;
  String signType;
  int domainType;

  DomainEntity({
    required this.domain,
    this.token = '',
    this.cdn = domainCdnF,
    this.openFlag = true,
    this.weight = 1,
    this.weightCnt = 1,
    this.signType = '',
  }) : domainType = getDomainCdnType(cdn);

  /// base64 映射 → 明文 URL；已是 http(s) 则原样返回（兼容旧缓存/旧 CDN）
  static String decodeMappedUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return s;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    try {
      final decoded = utf8.decode(base64.decode(s));
      if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
        return decoded;
      }
    } catch (_) {}
    return s;
  }

  /// 明文 URL → base64 映射（与硬编码域名同级处理）
  static String encodeMappedUrl(String url) {
    final plain = decodeMappedUrl(url);
    if (plain.isEmpty) return plain;
    return base64.encode(utf8.encode(plain));
  }

  factory DomainEntity.fromJson(Map<String, dynamic> json) {
    final weightRaw = json['weight'];
    final int weight =
        (weightRaw is num && weightRaw >= 1) ? weightRaw.toInt() : 1;
    return DomainEntity(
      domain: decodeMappedUrl((json['domain'] as String?)?.trim() ?? ''),
      token: json['token']?.toString() ?? '',
      cdn: json['cdn']?.toString() ?? domainCdnF,
      openFlag: json['openFlag'] is bool ? json['openFlag'] as bool : true,
      weight: weight,
      signType: json['signType']?.toString() ?? '',
    );
  }

  /// 仅有 URL 的兜底域名（方能，不加签）
  factory DomainEntity.urlOnly(String url, {int weight = 1}) {
    return DomainEntity(
      domain: decodeMappedUrl(url),
      token: '',
      cdn: domainCdnF,
      openFlag: false,
      weight: weight,
      signType: '',
    );
  }

  /// 持久化 / 写出时 domain 为 base64 映射
  Map<String, dynamic> toJson() => {
        'domain': encodeMappedUrl(domain),
        'token': token,
        'cdn': cdn,
        'openFlag': openFlag,
        'weight': weight,
        'signType': signType,
      };

  /// 对齐 XMSport：A=1 阿里, T=2 腾讯, H=3 华为, 其他=0 方能
  static int getDomainCdnType(String cdn) {
    if (cdn == domainCdnA) return 1;
    if (cdn == domainCdnT) return 2;
    if (cdn == domainCdnH) return 3;
    return 0;
  }

  String get host {
    try {
      final uri = Uri.parse(domain);
      return '${uri.scheme}://${uri.host}';
    } catch (_) {
      return domain;
    }
  }
}
