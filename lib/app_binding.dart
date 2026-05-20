import 'package:flutter/widgets.dart';

/// Custom binding that supports replacing the ImageCache at runtime.
/// B-side modules may use encrypted images that require a custom ImageCache
/// with decryption support. Since PaintingBinding._imageCache has no public
/// setter, we use a delegating wrapper created during binding initialization.
class AppBinding extends WidgetsFlutterBinding {
  static DelegatingImageCache? _appCache;

  static WidgetsBinding ensureInitialized() {
    if (_appCache == null) {
      AppBinding();
    }
    return WidgetsBinding.instance;
  }

  @override
  ImageCache createImageCache() {
    _appCache = DelegatingImageCache();
    return _appCache!;
  }

  /// B-side calls this to activate its custom ImageCache (e.g. with decryption)
  static void setImageCacheDelegate(ImageCache delegate) {
    _appCache?.delegate = delegate;
  }
}

/// ImageCache wrapper that delegates to an optional custom implementation.
/// Before delegate is set: uses default ImageCache behavior (A-side).
/// After delegate is set: all operations go through the delegate (B-side).
class DelegatingImageCache extends ImageCache {
  ImageCache? delegate;

  @override
  ImageStreamCompleter? putIfAbsent(
    Object key,
    ImageStreamCompleter Function() loader, {
    ImageErrorListener? onError,
  }) {
    if (delegate != null) {
      return delegate!.putIfAbsent(key, loader, onError: onError);
    }
    return super.putIfAbsent(key, loader, onError: onError);
  }

  @override
  bool evict(Object key, {bool includeLive = true}) {
    if (delegate != null) {
      return delegate!.evict(key, includeLive: includeLive);
    }
    return super.evict(key, includeLive: includeLive);
  }

  @override
  bool containsKey(Object key) {
    if (delegate != null) {
      return delegate!.containsKey(key);
    }
    return super.containsKey(key);
  }

  @override
  ImageCacheStatus statusForKey(Object key) {
    if (delegate != null) {
      return delegate!.statusForKey(key);
    }
    return super.statusForKey(key);
  }

  @override
  void clear() {
    delegate?.clear();
    super.clear();
  }

  @override
  void clearLiveImages() {
    delegate?.clearLiveImages();
    super.clearLiveImages();
  }

  @override
  int get maximumSize => delegate?.maximumSize ?? super.maximumSize;

  @override
  set maximumSize(int value) {
    if (delegate != null) delegate!.maximumSize = value;
    super.maximumSize = value;
  }

  @override
  int get currentSize => delegate?.currentSize ?? super.currentSize;

  @override
  int get maximumSizeBytes => delegate?.maximumSizeBytes ?? super.maximumSizeBytes;

  @override
  set maximumSizeBytes(int value) {
    if (delegate != null) delegate!.maximumSizeBytes = value;
    super.maximumSizeBytes = value;
  }

  @override
  int get currentSizeBytes => delegate?.currentSizeBytes ?? super.currentSizeBytes;

  @override
  int get liveImageCount => delegate?.liveImageCount ?? super.liveImageCount;

  @override
  int get pendingImageCount => delegate?.pendingImageCount ?? super.pendingImageCount;
}
