#!/bin/bash
# 写入 Secondary SVG 加载所需 Dart 文件
# 用法: bash scripts/write_svg_support_darts.sh [PROJECT_ROOT]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${1:-$(dirname "$SCRIPT_DIR")}"
UTILS_DIR="$PROJECT_ROOT/lib/utils"

mkdir -p "$UTILS_DIR"

cat > "$UTILS_DIR/secondary_svg_picture.dart" << 'EOF'
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_graphics/vector_graphics_compat.dart'
    show RenderingStrategy;

import '../modules/secondary/generate/secondary_svg_base64_map.dart';
import 'secondary_image_base64_ext.dart';

final Map<String, String?> _secondarySvgBase64Cache = <String, String?>{};
final Map<String, String?> _secondarySvgStringCache = <String, String?>{};

String? _resolveSecondarySvgBase64(String path) {
  return _secondarySvgBase64Cache.putIfAbsent(path, () {
    final name = path.split('/').isNotEmpty ? path.split('/').last : path;
    return SecondarySvgBase64Map.getByPath(path) ??
        SecondarySvgBase64Map.getByName(path) ??
        SecondarySvgBase64Map.getByName(name);
  });
}

String? _resolveSecondarySvgString(String path) {
  return _secondarySvgStringCache.putIfAbsent(path, () {
    final b64 = _resolveSecondarySvgBase64(path);
    if (b64 == null || b64.isEmpty) {
      return null;
    }
    return utf8.decode(base64Decode(b64), allowMalformed: true);
  });
}

class SecondarySvgPicture {
  const SecondarySvgPicture._();

  static Widget asset(
    String assetName, {
    Key? key,
    bool matchTextDirection = false,
    AssetBundle? bundle,
    String? package,
    double? width,
    double? height,
    BoxFit fit = BoxFit.contain,
    AlignmentGeometry alignment = Alignment.center,
    bool allowDrawingOutsideViewBox = false,
    WidgetBuilder? placeholderBuilder,
    String? semanticsLabel,
    bool excludeFromSemantics = false,
    Clip clipBehavior = Clip.hardEdge,
    SvgErrorWidgetBuilder? errorBuilder,
    SvgTheme? theme,
    ColorMapper? colorMapper,
    ui.ColorFilter? colorFilter,
    @Deprecated('Use colorFilter instead.') ui.Color? color,
    @Deprecated('Use colorFilter instead.')
    ui.BlendMode colorBlendMode = ui.BlendMode.srcIn,
    @Deprecated('This no longer does anything.') bool cacheColorFilter = false,
    RenderingStrategy renderingStrategy = RenderingStrategy.picture,
  }) {
    final normalizedName =
        package == null ? assetName.normalizedSecondaryImagePath() : assetName;
    final svgString =
        package == null ? _resolveSecondarySvgString(normalizedName) : null;

    if (svgString != null && svgString.isNotEmpty) {
      return SvgPicture.string(
        svgString,
        key: key,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        matchTextDirection: matchTextDirection,
        allowDrawingOutsideViewBox: allowDrawingOutsideViewBox,
        placeholderBuilder: placeholderBuilder,
        semanticsLabel: semanticsLabel,
        excludeFromSemantics: excludeFromSemantics,
        clipBehavior: clipBehavior,
        errorBuilder: errorBuilder,
        theme: theme,
        colorMapper: colorMapper,
        colorFilter: colorFilter,
        color: color,
        colorBlendMode: colorBlendMode,
        cacheColorFilter: cacheColorFilter,
        renderingStrategy: renderingStrategy,
      );
    }

    return SvgPicture.asset(
      normalizedName,
      key: key,
      matchTextDirection: matchTextDirection,
      bundle: bundle,
      package: package,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      allowDrawingOutsideViewBox: allowDrawingOutsideViewBox,
      placeholderBuilder: placeholderBuilder,
      semanticsLabel: semanticsLabel,
      excludeFromSemantics: excludeFromSemantics,
      clipBehavior: clipBehavior,
      errorBuilder: errorBuilder,
      theme: theme,
      colorMapper: colorMapper,
      colorFilter: colorFilter,
      color: color,
      colorBlendMode: colorBlendMode,
      cacheColorFilter: cacheColorFilter,
      renderingStrategy: renderingStrategy,
    );
  }
}
EOF
