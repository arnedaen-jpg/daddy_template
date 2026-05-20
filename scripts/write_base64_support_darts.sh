#!/bin/bash
# 写入 Base64 图片加载所需的 Dart 文件（仅在启用 --base64-map / --replace-image-entry 时由同步脚本调用）
# 用法: bash scripts/write_base64_support_darts.sh [PROJECT_ROOT]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-$(dirname "$SCRIPT_DIR")}"
UTILS_DIR="$PROJECT_ROOT/lib/utils"

mkdir -p "$UTILS_DIR"

write_ext() {
  cat > "$UTILS_DIR/secondary_image_base64_ext.dart" << 'EOF'
import 'dart:convert';
import 'dart:typed_data';

import '../modules/secondary/generate/secondary_image_base64_map.dart';

final Map<String, String?> _secondaryImageBase64Cache = <String, String?>{};
final Map<String, Uint8List> _secondaryImageBytesCache = <String, Uint8List>{};

String _normalizeSecondaryImagePath(String path) {
  if (path.startsWith('assets/') && !path.contains('assets/secondary/')) {
    return path.replaceFirst('assets/', 'assets/secondary/');
  }
  if (path.startsWith('assetsholiday/') && !path.contains('assets/secondary/')) {
    return path.replaceFirst(
      'assetsholiday/',
      'assets/secondary/assetsholiday/',
    );
  }
  return path;
}

String? _resolveSecondaryImageBase64(String path) {
  final newPath = _normalizeSecondaryImagePath(path);
  return _secondaryImageBase64Cache.putIfAbsent(newPath, () {
    final name = newPath.split('/').isNotEmpty ? newPath.split('/').last : newPath;
    return SecondaryImageBase64Map.getByPath(newPath) ??
        SecondaryImageBase64Map.getByName(newPath) ??
        SecondaryImageBase64Map.getByName(name);
  });
}

Uint8List _resolveSecondaryImageBytes(String path) {
  final newPath = _normalizeSecondaryImagePath(path);
  return _secondaryImageBytesCache.putIfAbsent(newPath, () {
    final String? b64 = _resolveSecondaryImageBase64(newPath);
    if (b64 == null || b64.isEmpty) {
      return Uint8List(0);
    }
    return base64Decode(b64);
  });
}

extension SecondaryImageBase64Ext on String {
  /// 按路径优先、文件名回退读取 Base64，并解码成 bytes。
  Uint8List base64data() => _resolveSecondaryImageBytes(this);

  String normalizedSecondaryImagePath() => _normalizeSecondaryImagePath(this);

  String fixPath(String path) => _normalizeSecondaryImagePath(path);
}
EOF
}

write_base_hh() {
  cat > "$UTILS_DIR/base_hh_image.dart" << 'EOF'
import 'package:flutter/widgets.dart';

import 'secondary_image_base64_ext.dart';

final Map<String, MemoryImage> _secondaryMemoryImageCache =
    <String, MemoryImage>{};

/// 为 `AssetImage/ExactAssetImage` 场景提供兼容的 ImageProvider。
///
/// 当图片已进入 Base64 映射时走 [MemoryImage]，否则回退到普通 [AssetImage]。
ImageProvider<Object> secondaryAssetProvider(
  String name, {
  AssetBundle? bundle,
  String? package,
  double scale = 1.0,
}) {
  final normalizedName = name.normalizedSecondaryImagePath();
  final bytes = normalizedName.base64data();
  if (bytes.isNotEmpty) {
    final cacheKey = '$normalizedName@$scale';
    return _secondaryMemoryImageCache.putIfAbsent(
      cacheKey,
      () => MemoryImage(bytes, scale: scale),
    );
  }
  return AssetImage(normalizedName, bundle: bundle, package: package);
}

Image _buildSecondaryImage({
  required String name,
  Key? key,
  AssetBundle? bundle,
  ImageFrameBuilder? frameBuilder,
  ImageErrorWidgetBuilder? errorBuilder,
  String? semanticLabel,
  bool excludeFromSemantics = false,
  double? scale,
  double? width,
  double? height,
  Color? color,
  Animation<double>? opacity,
  BlendMode? colorBlendMode,
  BoxFit? fit,
  AlignmentGeometry alignment = Alignment.center,
  ImageRepeat repeat = ImageRepeat.noRepeat,
  Rect? centerSlice,
  bool matchTextDirection = false,
  bool gaplessPlayback = false,
  bool isAntiAlias = false,
  String? package,
  FilterQuality filterQuality = FilterQuality.medium,
  int? cacheWidth,
  int? cacheHeight,
}) {
  return Image(
    key: key,
    image: ResizeImage.resizeIfNeeded(
      cacheWidth,
      cacheHeight,
      secondaryAssetProvider(
        name,
        bundle: bundle,
        package: package,
        scale: scale ?? 1.0,
      ),
    ),
    frameBuilder: frameBuilder,
    errorBuilder: errorBuilder,
    semanticLabel: semanticLabel,
    excludeFromSemantics: excludeFromSemantics,
    width: width,
    height: height,
    color: color,
    opacity: opacity,
    colorBlendMode: colorBlendMode,
    fit: fit,
    alignment: alignment,
    repeat: repeat,
    centerSlice: centerSlice,
    matchTextDirection: matchTextDirection,
    gaplessPlayback: gaplessPlayback,
    isAntiAlias: isAntiAlias,
    filterQuality: filterQuality,
  );
}

/// 与 [Image.asset] 构造参数对齐，内部复用缓存后的 ImageProvider。
class BaseHHImage extends StatelessWidget {
  const BaseHHImage(
    this.name, {
    super.key,
    this.bundle,
    this.frameBuilder,
    this.errorBuilder,
    this.semanticLabel,
    this.excludeFromSemantics = false,
    this.scale,
    this.width,
    this.height,
    this.color,
    this.opacity,
    this.colorBlendMode,
    this.fit,
    this.alignment = Alignment.center,
    this.repeat = ImageRepeat.noRepeat,
    this.centerSlice,
    this.matchTextDirection = false,
    this.gaplessPlayback = false,
    this.isAntiAlias = false,
    this.package,
    this.filterQuality = FilterQuality.medium,
    this.cacheWidth,
    this.cacheHeight,
  })  : assert(cacheWidth == null || cacheWidth > 0),
        assert(cacheHeight == null || cacheHeight > 0);

  /// Returns a raw [Image] for legacy call sites that require `Image` type.
  static Image image(
    String name, {
    Key? key,
    AssetBundle? bundle,
    ImageFrameBuilder? frameBuilder,
    ImageErrorWidgetBuilder? errorBuilder,
    String? semanticLabel,
    bool excludeFromSemantics = false,
    double? scale,
    double? width,
    double? height,
    Color? color,
    Animation<double>? opacity,
    BlendMode? colorBlendMode,
    BoxFit? fit,
    AlignmentGeometry alignment = Alignment.center,
    ImageRepeat repeat = ImageRepeat.noRepeat,
    Rect? centerSlice,
    bool matchTextDirection = false,
    bool gaplessPlayback = false,
    bool isAntiAlias = false,
    String? package,
    FilterQuality filterQuality = FilterQuality.medium,
    int? cacheWidth,
    int? cacheHeight,
  }) {
    assert(cacheWidth == null || cacheWidth > 0);
    assert(cacheHeight == null || cacheHeight > 0);
    return _buildSecondaryImage(
      name: name,
      key: key,
      bundle: bundle,
      scale: scale,
      frameBuilder: frameBuilder,
      errorBuilder: errorBuilder,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      width: width,
      height: height,
      color: color,
      opacity: opacity,
      colorBlendMode: colorBlendMode,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      centerSlice: centerSlice,
      matchTextDirection: matchTextDirection,
      gaplessPlayback: gaplessPlayback,
      isAntiAlias: isAntiAlias,
      package: package,
      filterQuality: filterQuality,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
  }

  final String name;
  final AssetBundle? bundle;
  final ImageFrameBuilder? frameBuilder;
  final ImageErrorWidgetBuilder? errorBuilder;
  final String? semanticLabel;
  final bool excludeFromSemantics;
  final double? scale;
  final double? width;
  final double? height;
  final Color? color;
  final Animation<double>? opacity;
  final BlendMode? colorBlendMode;
  final BoxFit? fit;
  final AlignmentGeometry alignment;
  final ImageRepeat repeat;
  final Rect? centerSlice;
  final bool matchTextDirection;
  final bool gaplessPlayback;
  final bool isAntiAlias;
  final String? package;
  final FilterQuality filterQuality;
  final int? cacheWidth;
  final int? cacheHeight;

  @override
  Widget build(BuildContext context) {
    return _buildSecondaryImage(
      name: name,
      key: key,
      bundle: bundle,
      scale: scale,
      frameBuilder: frameBuilder,
      errorBuilder: errorBuilder,
      semanticLabel: semanticLabel,
      excludeFromSemantics: excludeFromSemantics,
      width: width,
      height: height,
      color: color,
      opacity: opacity,
      colorBlendMode: colorBlendMode,
      fit: fit,
      alignment: alignment,
      repeat: repeat,
      centerSlice: centerSlice,
      matchTextDirection: matchTextDirection,
      gaplessPlayback: gaplessPlayback,
      isAntiAlias: isAntiAlias,
      package: package,
      filterQuality: filterQuality,
      cacheWidth: cacheWidth,
      cacheHeight: cacheHeight,
    );
  }
}
EOF
}

MODE="${2:-all}"

case "$MODE" in
  ext-only)
    write_ext
    ;;
  base-hh-only)
    write_base_hh
    ;;
  all)
    write_ext
    write_base_hh
    ;;
  *)
    echo "Unknown mode: $MODE (use all|ext-only|base-hh-only)" >&2
    exit 1
    ;;
esac
