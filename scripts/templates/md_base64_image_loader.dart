import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

// import removed: svg_net_provider no longer used with flutter_svg 2.x

import 'package:cached_network_image/cached_network_image.dart';
import 'package:color_thief_dart/color_thief_dart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_base/flutter_base.dart';
import 'package:flutter_base/image/decrypt_image.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'secondary_image_base64_ext.dart';
import 'base_hh_image.dart';

/// 加载图片和svg的处理函数
enum ImgType {
  FILE,
  ASSETS,
  SVG,
  HTTP_SVG,
  HTTP_ASSETS,
}

class ImageLoader {
  ImageLoader.withP(
    this.address, {
    this.package,
    this.scale = 1.0,
    this.radius = .0,
    this.type,
    this.thumb = true,
    this.isGauss = false,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.color,
    this.placeholder,
    this.loadError,
    this.isResizeImage = true,
    this.fastFade = false,
  });

  String address; //url地址
  String? loaderImg;
  final String? package;
  final double? width;
  final double? height;
  final bool isGauss;
  final double scale;
  final BoxFit fit;
  final Color? color;
  final Alignment alignment;
  final double radius;
  ImgType? type;
  final Widget? placeholder;
  final Widget? loadError;
  final bool? isResizeImage; //是否需要根据组件大小压缩
  final bool fastFade;
  /// 是否显示成缩略图：图片是否根据传入的宽高自动裁剪
  bool thumb = false;

  // 本地资源是否存在
  static bool _nativeIconExisted = true;
  static BaseCacheManager? _cacheManager;
  static ValueGetter<String>? _cdnGetter;
  static String? _projectName;
  static String? _projectFullVersion;
  static Completer<bool>? _initCompleter;

  ///测试本地资源是走网路还是本地
  ///[nativeAddress]
  static Future<bool> init(
    String nativeAddress, {
    BaseCacheManager? cacheManager,
    String? projectName,
    String? projectFullVersion,
    ValueGetter<String>? cdnGetter,
  }) {
    _cacheManager = cacheManager ?? MyImageCacheManager();
    if (null != cdnGetter) _cdnGetter = cdnGetter;
    if (null != projectName) _projectName = projectName;
    if (null != projectFullVersion) _projectFullVersion = projectFullVersion;
    if (TextUtil.isEmpty(nativeAddress) || nativeAddress.startsWith("http") || !isIconPath(nativeAddress)) {
      return Future.value(true);
    }
    if (_initCompleter == null) {
      _initCompleter = Completer();
      () async {
        try {
          await rootBundle.load(nativeAddress);
          _nativeIconExisted = true;
        } catch (e) {
          _nativeIconExisted = false;
        }
        _initCompleter?.complete(_nativeIconExisted);
      }();
    }
    return _initCompleter!.future;
  }

  static ValueGetter<String>? get cdnGetter => _cdnGetter;

  static String _fixSecondaryAssetPath(String p) {
    if (p.startsWith('assets/') && !p.contains('assets/secondary/')) {
      return p.replaceFirst('assets/', 'assets/secondary/');
    }
    return p;
  }

  ImageProvider<Object>? loadMemory() {
    init(address);
    address = _fixSecondaryAssetPath(address);
    ImageProvider<Object>? content;
    if (!TextUtil.isEmpty(address)) {
      type = ImgType.HTTP_ASSETS;
      if (address.startsWith("http")) {
      } else if (isIconPath(address)
          // && address.contains(_projectName)
          ) {
        thumb = false;
        if (address.endsWith(".svg")) {
          if (_nativeIconExisted) {
            type = ImgType.SVG;
          } else {
            type = ImgType.HTTP_SVG;
            if (_projectName != null && _projectFullVersion != null) {
              address = address.replaceAll(_projectName!, "${_projectName!}${path.separator}${_projectFullVersion!}");
            }
          }
        } else {
          // 栅格图走 Base64 映射 + MemoryImage，不依赖 rootBundle 探测
          type = ImgType.ASSETS;
        }
      }
      // SVG 不支持 ImageProvider（Image.memory/AssetImage），交由 load() 走 SvgPicture.* 分支
      if (type == ImgType.SVG || type == ImgType.HTTP_SVG) {
        return null;
      }
      if (type == ImgType.ASSETS) {
        final bytes = address.base64data();
        if (bytes.isEmpty) {
          content = AssetImage(address);
        } else {
          content = MemoryImage(bytes);
        }
      } else {
        var remoteUrl = getImageUrl(address);
        if (!remoteUrl.startsWith("http") && !remoteUrl.startsWith("https")) {
          remoteUrl = path.join(_cdnGetter?.call() ?? '', remoteUrl);
        }
        // content = ImageNetProvider(remoteUrl);
        content = CachedNetworkImageProvider(remoteUrl, cacheManager: _cacheManager);
      }
    }
    return content;
  }

  /// 加载图片
  Widget load() {
    init(address);
    address = _fixSecondaryAssetPath(address);
    Widget child;
    if (TextUtil.isEmpty(address)) {
      child = placeholder ??
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey),
              color: Colors.grey[200],
            ),
            width: width,
            height: height,
            child: Center(
              child: Text("暂无图片", style: TextStyle(color: Colors.black)),
            ),
          );
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      );
    }

    type ??= resetImgType(address, package: package);
    if (isAddressNoThumb(address)) thumb = false;

    switch (this.type) {
      case ImgType.FILE:
        child = Image.file(File(address), width: width, height: height, fit: fit, color: color);
        break;
      case ImgType.ASSETS:
        final img = BaseHHImage(address, package: package, width: width, height: height, fit: fit);
        if (color != null) {
          child = ColorFiltered(colorFilter: ColorFilter.mode(color!, BlendMode.srcIn), child: img);
        } else {
          child = img;
        }
        break;
      case ImgType.SVG:
        child = SvgPicture.asset(address,
            width: width,
            height: height,
            package: package,
            fit: fit,
            // placeholderBuilder: (context) =>
            //     SpinKitFadingCircle(size: width, color: Colors.black),
            colorFilter: color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn));
        break;
      case ImgType.HTTP_SVG:
        if (isIconPath(address)) {
          if (_projectName != null && _projectFullVersion != null) {
            address = address.replaceAll(_projectName!, "${_projectName!}${path.separator}${_projectFullVersion!}");
          }
        }
        var remoteUrl =
            getImageUrl(address, hasGauss: isGauss, width: width, height: height, thumb: thumb, scale: scale, fit: fit);
        child = FutureBuilder<Uint8List>(
          future: (() async {
            final client = http.Client();
            final req = http.Request('GET', Uri.parse(remoteUrl));
            req.headers['cache-control'] = 'max-age=31104000';
            final res = await client.send(req);
            final bytes = await res.stream.toBytes();
            return decryptImage(bytes);
          })(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return placeholder ?? SizedBox(width: width, height: height);
            }
            if (!snapshot.hasData) {
              return loadError ?? const Icon(Icons.error);
            }
            return SvgPicture.memory(
              snapshot.data!,
              width: width,
              height: height,
              fit: fit,
              colorFilter: color == null ? null : ColorFilter.mode(color!, BlendMode.srcIn),
            );
          },
        );
        break;
      case ImgType.HTTP_ASSETS:
        if (isIconPath(address)) {
          if (_projectName != null && _projectFullVersion != null) {
            address = address.replaceAll(_projectName!, "${_projectName!}${path.separator}${_projectFullVersion!}");
          }
        }
        // print("ImgType.HTTP....address:$address");
        final hasKnownWidth = (width ?? 0) > 0 && (width ?? 0).isFinite;
        final hasKnownHeight = (height ?? 0) > 0 && (height ?? 0).isFinite;
        if (hasKnownWidth && hasKnownHeight) {
          // 宽高已知，直接构建，跳过 LayoutBuilder 减少 layout pass
          final remoteUrl = getImageUrl(address,
              hasGauss: isGauss, width: width, height: height,
              thumb: thumb, scale: scale, fit: fit);
          final w = (width! * screen.devicePixelRatio).toInt();
          final cacheWidth = w > 0 ? (w > 1440 ? 1440 : w) : null;
          child = CachedNetworkImage(
            imageUrl: remoteUrl,
            alignment: alignment,
            width: width,
            height: height,
            memCacheWidth: cacheWidth,
            color: color,
            fadeInDuration: Duration(milliseconds: fastFade ? 0 : 100),
            fadeOutDuration: Duration(milliseconds: fastFade ? 0 : 50),
            fadeInCurve: Curves.easeOut,
            fadeOutCurve: Curves.easeIn,
            cacheManager: _cacheManager,
            fit: fit,
            progressIndicatorBuilder: (c, url, p) => placeholder ?? Container(),
            errorWidget: (context, error, stacktrace) => loadError ?? const Icon(Icons.error),
          );
        } else {
          child = LayoutBuilder(
            builder: (context, constraints) {
              var remoteUrl = getImageUrl(
                address,
                hasGauss: isGauss,
                width: hasKnownWidth ? width! : constraints.maxWidth,
                height: hasKnownHeight ? height! : constraints.maxHeight,
                thumb: thumb,
                scale: scale,
                fit: fit,
              );
              return CachedNetworkImage(
                imageUrl: remoteUrl,
                alignment: alignment,
                width: width,
                height: height,
                memCacheWidth: memCacheWidth(constraints),
                color: color,
                fadeInDuration: Duration(milliseconds: fastFade ? 0 : 100),
                fadeOutDuration: Duration(milliseconds: fastFade ? 0 : 50),
                fadeInCurve: Curves.easeOut,
                fadeOutCurve: Curves.easeIn,
                cacheManager: _cacheManager,
                fit: fit,
                progressIndicatorBuilder: (c, url, p) => placeholder ?? Container(),
                errorWidget: (context, error, stacktrace) => loadError ?? const Icon(Icons.error),
              );
            },
          );
        }
        break;
      default:
        child = Container();
        break;
    }
    if (radius > 0) {
      return ClipRRect(borderRadius: BorderRadius.circular(radius), child: child);
    }
    return child;
  }

  //resize的宽度，图片过载
    // 优化：限制最大内存缓存宽度，避免过度解码导致性能问题
  int? memCacheWidth(BoxConstraints cons) {
    if (isResizeImage == true) {
      if (cons.maxWidth == double.infinity || cons.maxWidth.isNaN) {
        return null;
      }
      // 限制最大宽度为屏幕宽度的2倍，避免过度解码
      final maxWidth = (cons.maxWidth * screen.devicePixelRatio).toInt();
      return maxWidth > 0 ? (maxWidth > 1440 ? 1440 : maxWidth) : null;
    } else {
      if (width != null && width! > 0) {
        final w = (width! * screen.devicePixelRatio).toInt();
        return w > 1440 ? 1440 : w;
      }
      final screenWidth = (Get.width * screen.devicePixelRatio).toInt();
      return screenWidth > 1440 ? 1440 : screenWidth;    }
  }

  /// 根据路径重置ImageType
  ImgType resetImgType(String address, {String? package}) {
    ImgType type;
    if (address.startsWith("file://")) {
      type = ImgType.FILE;
    } else if (address.startsWith("http")) {
      // 是远程路径 或者 本地资源不存在
      if (address.endsWith(".svg")) {
        type = ImgType.HTTP_SVG;
      } else {
        type = ImgType.HTTP_ASSETS;
      }
    } else if (address.endsWith(".svg")) {
      // 本地 SVG 统一走 SvgPicture.asset（不依赖 _nativeIconExisted 的全局探测结果）
      type = ImgType.SVG;
    } else if (TextUtil.isNotEmpty(package) || address.contains("/local/")) {
      // 有包名，强制本地路径
      type = ImgType.ASSETS;
    } else if (isIconPath(address)) {
      // 栅格图走 BaseHHImage（base64data），避免 bundle 无文件时被误判为 HTTP
      type = ImgType.ASSETS;
    } else {
      // 默认是远程
      type = ImgType.HTTP_ASSETS;
    }
    return type;
  }

  /// 是否是本地图片路径
  static bool isIconPath(String address) {
    return address.contains("assets") && !address.contains("pulic_assets");
  }

  /// 检查地址强制不需要缩略图的情况
  static bool isAddressNoThumb(String address) {
    //svg和gif和应用图标不需要缩略图，否则失真和gif不展示
    if (address.endsWith(".svg") || address.endsWith(".gif") || address.endsWith(".webp") || isIconPath(address)) {
      return true;
    }
    return false;
  }

  /// 获取网络图片尺寸
  Future getNetImgSize() async {
    Completer completer = new Completer();
    init(address);
    if (!TextUtil.isEmpty(address)) {
      var remoteUrl = getImageUrl(address);
      if (!remoteUrl.startsWith("http") && !remoteUrl.startsWith("https")) {
        remoteUrl = path.join(_cdnGetter?.call() ?? '', remoteUrl);
      }
      Image imageNetwork = Image(image: new CachedNetworkImageProvider(remoteUrl, cacheManager: _cacheManager));
      imageNetwork.image.resolve(ImageConfiguration()).addListener(ImageStreamListener((ImageInfo info, bool _) {
        Map<String, int> size = {};
        size['width'] = info.image.width;
        size['height'] = info.image.height;
        completer.complete(size);
      }));
    }
    return completer.future;
  }

  /// 获取网络图片尺寸
  getNetImagegSize(ValueChanged callback) {
    init(address);
    if (!TextUtil.isEmpty(address)) {
      var remoteUrl = getImageUrl(address);
      if (!remoteUrl.startsWith("http") && !remoteUrl.startsWith("https")) {
        remoteUrl = path.join(_cdnGetter?.call() ?? '', remoteUrl);
      }
      Image imageNetwork = Image(image: new CachedNetworkImageProvider(remoteUrl, cacheManager: _cacheManager));
      imageNetwork.image.resolve(ImageConfiguration()).addListener(ImageStreamListener((ImageInfo info, bool _) {
        Map<String, int> size = {};
        size['width'] = info.image.width;
        size['height'] = info.image.height;
        callback(size);
      }));
    }
  }

  /// 获取网络图片最大基色
  static Future getNetImgMostColor(String url) async {
    List<int> colorRGB = [];
    Completer<List<int>> completer = new Completer();
    if (!TextUtil.isEmpty(url)) {
      var remoteUrl = getImageUrl(url);
      if (!remoteUrl.startsWith("http") && !remoteUrl.startsWith("https")) {
        remoteUrl = path.join(_cdnGetter?.call() ?? '', remoteUrl);
      }
      Image imageNetwork = Image(image: new CachedNetworkImageProvider(remoteUrl, cacheManager: _cacheManager));
      imageNetwork.image.resolve(ImageConfiguration()).addListener(ImageStreamListener((ImageInfo info, bool _) async {
        colorRGB = (await getColorFromImage(info.image)) ?? <int>[];
        completer.complete(colorRGB);
      }));
    }
    return completer.future;
  }

  /// 获取图片流
  static Future<ui.Image> getNetImgStream(String url) async {
    late ImageStream stream;
    final completer = Completer<ui.Image>();
    if (!TextUtil.isEmpty(url)) {
      var remoteUrl = getImageUrl(url);
      if (!remoteUrl.startsWith("http") && !remoteUrl.startsWith("https")) {
        remoteUrl = path.join(_cdnGetter?.call() ?? '', remoteUrl);
      }
      final imageNetwork = Image(image: CachedNetworkImageProvider(remoteUrl, cacheManager: _cacheManager));
      stream = imageNetwork.image.resolve(const ImageConfiguration());
      void listener(ImageInfo frame, bool synchrononousCall) {
        final ui.Image image = frame.image;
        completer.complete(image);
        stream.removeListener(ImageStreamListener(listener));
      }

      stream.addListener(ImageStreamListener(listener));
    }
    return completer.future;
  }

  Future deleteNetImageFromCatch() async {
    init(address);
    if (!TextUtil.isEmpty(address)) {
      var remoteUrl = getImageUrl(address);
      if (!remoteUrl.startsWith("http") && !remoteUrl.startsWith("https")) {
        remoteUrl = path.join(_cdnGetter?.call() ?? '', remoteUrl);
      }
      await DefaultCacheManager().removeFile(remoteUrl);
      await CachedNetworkImage.evictFromCache(remoteUrl, cacheManager: _cacheManager);
    }
  }

  /// 预加载图片
  Future preCache(BuildContext context) async {
    switch (type) {
      case ImgType.SVG:
        try {
          await rootBundle.loadString(address);
        } catch (_) {
          // ignore: precache best-effort
        }
        break;
      case ImgType.ASSETS:
        final bytes = address.base64data();
        if (bytes.isEmpty) {
          await precacheImage(AssetImage(address), context);
        } else {
          await precacheImage(MemoryImage(bytes), context);
        }
        break;
      case ImgType.HTTP_ASSETS:
        await _cacheManager?.getSingleFile(getImageUrl(address, width: width, height: height, hasGauss: isGauss));

        break;
      default:
        break;
    }
  }

//   static preloadVideoImg(VideoModel videoModel) async {
//     if (TextUtil.isEmpty(videoModel?.cover)) return;
//     var resolution = configVerticalVideoSize(
//         screen.screenWidth,
//         screen.screenHeight,
//         videoModel.resolutionWidth,
//         videoModel.resolutionHeight);
//     var remoteImgUrl = getImagePath(
//       videoModel.cover,
//       false,
//       false,
//       width: resolution.videoWidth ?? double.infinity,
//       height: resolution.videoHeight ?? double.infinity,
//     );
// //    l.i("preload", "开始缓存网络图片url:$remoteImgUrl");
//     ImageCacheManager().getSingleFile(remoteImgUrl).then((f) {
// //      l.i("preload",
// //          "preloadVideoImg()...缓存网络图片成功url:$remoteImgUrl ==> ${f.path}");
//     }).catchError((e) {
// //      l.e("preload", "preloadVideoImg()...缓存网络图片失败url:$remoteImgUrl ==> $e");
//     });
//   }

  /// 获取图片的远程url
  /// [imgPath] 图片的相对路径或者绝对路径
  /// [hasGauss] 是否需要服务器高斯默认高斯值40
  /// [width], [height] 是否需要服务器裁剪宽高，默认不传
  /// [thumb] 是否显示成缩略图,如果是，将会根据宽高让服务器自动裁剪图片
  static String getImageUrl(String imgPath,
      {bool hasGauss = false,
      double? width,
      double? height,
      bool thumb = false,
      double scale = 1.0,
      BoxFit fit = BoxFit.cover}) {
    if (TextUtil.isEmpty(imgPath)) {
      l.e("image", "getImageUrl()...path is empty", stackTrace: StackTrace.current);
      return "";
    }
    if (imgPath.startsWith("http") || imgPath.startsWith("https")) {
      return imgPath;
    }
    if (imgPath.startsWith("/")) {
      imgPath = imgPath.replaceFirst(RegExp(r'/'), '');
    }

    bool hasWidth = (width ?? 0) > 0 && (width ?? 0).isFinite;
    bool hasHeight = (height ?? 0) > 0 && (height ?? 0).isFinite;

    String remotePath = _cdnGetter?.call() ?? '';
    if (thumb || hasGauss) {
      int mode = 0;
      // mode: 后端提供之图片尺寸适配模式
      // 0: 原图
      // 1: 缩放，只提供w或h之一时将等比缩放，若w和h同时存在将拉抻变形
      // 2. 等比缩放，居中裁剪(不变形)，w和h都必须提供
      if (fit == BoxFit.cover && hasHeight && hasWidth) {
        // 中心裁剪适配
        mode = 2;
        remotePath = path.joinAll([
          "imageView/$mode",
          "w/${(width! * screen.devicePixelRatio).round()}",
          "h/${(height! * screen.devicePixelRatio).round()}",
          if (hasGauss) "s/$DEF_GAUSS_VALUE",
        ]);
      } else if ((fit == BoxFit.fitWidth && hasWidth)) {
        // 部分适配宽
        mode = 1;
        remotePath = path.joinAll([
          "imageView/$mode",
          "w/${(width! * screen.devicePixelRatio).round()}",
          // "h/${(height * screen.devicePixelRatio).round()}",
          if (hasGauss) "s/$DEF_GAUSS_VALUE",
        ]);
      } else if ((fit == BoxFit.fitHeight && hasHeight)) {
        // 部分适配高
        mode = 1;
        remotePath = path.joinAll([
          "imageView/$mode",
          // "w/${(width * screen.devicePixelRatio).round()}",
          "h/${(height! * screen.devicePixelRatio).round()}",
          if (hasGauss) "s/$DEF_GAUSS_VALUE",
        ]);
      } else if ((fit == BoxFit.contain && (hasHeight || hasWidth))) {
        // 部分适配
        mode = 1;
        if (hasWidth) {
          remotePath = path.joinAll([
            "imageView/$mode",
            "w/${(width! * screen.devicePixelRatio * scale).round()}",
            // "h/${(height * screen.devicePixelRatio * scale).round()}",
            if (hasGauss) "s/$DEF_GAUSS_VALUE",
          ]);
        } else if (hasHeight) {
          remotePath = path.joinAll([
            "imageView/$mode",
            // "w/${(width * screen.devicePixelRatio * scale).round()}",
            "h/${(height! * screen.devicePixelRatio * scale).round()}",
            if (hasGauss) "s/$DEF_GAUSS_VALUE",
          ]);
        }
      } else {
        // 原图
        mode = 0;
        remotePath = path.joinAll([
          "imageView/$mode",
          // if (hasWidth) "w/${(width * screen.devicePixelRatio).round()}",
          // if (hasHeight) "h/${(height * screen.devicePixelRatio).round()}",
          if (hasGauss) "s/$DEF_GAUSS_VALUE",
        ]);
      }
      // l.i("image",
      //     "getImageUrl()...begin thumb:$thumb imgPath:$imgPath hasGauss:$hasGauss width:$width height:$height mode:$mode fit:$fit hasWidth:$hasWidth hasHeight:$hasHeight");
    }
    // else {
    //   remotePath = Address.imgCdn;
    // }
    remotePath = path.join(remotePath, imgPath);

    // l.i("image", "getImageUrl()...end remotePath:$remotePath");
    return remotePath;
  }
}

ColorFilter? getColorFilter(Color? color, BlendMode? colorBlendMode) =>
    color == null ? null : ColorFilter.mode(color, colorBlendMode ?? BlendMode.srcIn);

// 默认高斯模糊值
const DEF_GAUSS_VALUE = 30;
