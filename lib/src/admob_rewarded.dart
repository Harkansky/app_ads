import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'rewarded_backend.dart';

/// Google's public test IDs. Debug builds should always use these: tapping
/// your own real ads can get the AdMob account suspended.
abstract final class AdMobTestIds {
  static const androidAppId = 'ca-app-pub-3940256099942544~3347511713';
  static const iosAppId = 'ca-app-pub-3940256099942544~1458002511';
  static const androidRewarded = 'ca-app-pub-3940256099942544/5224354917';
  static const iosRewarded = 'ca-app-pub-3940256099942544/1712485313';
}

/// Rewarded ads from Google AdMob, with Google's consent form, that never
/// make the app wait on the network.
///
/// - [init] gathers consent and starts the SDK in the background. Offline it
///   gives up quietly and tries again when the app comes back to the
///   foreground.
/// - One ad is kept loaded. Failed loads are retried with a growing delay
///   (15 s up to 10 min), and right away when the app is resumed.
/// - A loaded ad is replaced after [maxAge] (AdMob ads go stale).
/// - [isReady] is true only when an ad can be shown right now: show the
///   "watch an ad" button only then.
/// - [show] returns true only if the SDK reported the reward as earned.
class AdMobRewarded extends ChangeNotifier with WidgetsBindingObserver {
  AdMobRewarded({
    required this.adUnitId,
    this.debugEea = false,
    @visibleForTesting RewardedBackend? backend,
    @visibleForTesting this.maxAge = const Duration(minutes: 55),
    @visibleForTesting this._observeLifecycle = true,
  }) : _backend = backend ?? const GoogleRewardedBackend();

  /// The rewarded ad unit (AdMob > Apps > Ad units).
  final String adUnitId;

  /// Makes Google's consent form behave as in the EEA, to test it on a
  /// device outside Europe. Debug builds only.
  final bool debugEea;

  /// How long a loaded ad is kept before being replaced by a fresh one.
  final Duration maxAge;

  final RewardedBackend _backend;
  final bool _observeLifecycle;

  bool _started = false;
  bool _settingUp = false;
  bool _sdkReady = false;
  bool _loading = false;
  bool _showing = false;
  bool _disposed = false;
  bool _privacyOptionsRequired = false;
  int _failures = 0;
  LoadedRewardedAd? _ad;
  Timer? _retry;
  Timer? _expiry;

  /// Whether an ad can be shown right now.
  bool get isReady => _ad != null && !_showing;

  /// Whether Settings must offer "Privacy settings" (Google requires a way to
  /// change consent where the consent form applies).
  bool get privacyOptionsRequired => _privacyOptionsRequired;

  /// Starts consent and loading in the background. Safe to call more than
  /// once; never throws.
  Future<void> init() async {
    if (_started || _disposed) return;
    _started = true;
    if (_observeLifecycle) WidgetsBinding.instance.addObserver(this);
    await _setUp();
  }

  Future<void> _setUp() async {
    if (_sdkReady || _settingUp || _disposed) return;
    _settingUp = true;
    try {
      final canRequest = await _backend.gatherConsent(debugEea: debugEea);
      await _refreshPrivacyOptions();
      if (!canRequest || _disposed) return;
      await _backend.initializeSdk();
      _sdkReady = true;
    } catch (error) {
      debugPrint('app_ads: setup failed: $error');
    } finally {
      _settingUp = false;
    }
    if (_sdkReady) unawaited(_load());
  }

  Future<void> _refreshPrivacyOptions() async {
    try {
      final required = await _backend.privacyOptionsRequired();
      if (required != _privacyOptionsRequired && !_disposed) {
        _privacyOptionsRequired = required;
        notifyListeners();
      }
    } catch (error) {
      debugPrint('app_ads: privacy options status failed: $error');
    }
  }

  Future<void> _load() async {
    if (!_sdkReady || _loading || _ad != null || _disposed) return;
    _loading = true;
    _retry?.cancel();
    LoadedRewardedAd? ad;
    try {
      ad = await _backend.load(adUnitId);
    } catch (error) {
      debugPrint('app_ads: load failed: $error');
    }
    _loading = false;
    if (_disposed) {
      ad?.dispose();
      return;
    }
    if (ad == null) {
      _retry = Timer(retryDelay(_failures++), () => unawaited(_load()));
      return;
    }
    _failures = 0;
    _ad = ad;
    _expiry?.cancel();
    _expiry = Timer(maxAge, _replaceStaleAd);
    notifyListeners();
  }

  void _replaceStaleAd() {
    if (_showing || _disposed) return;
    _ad?.dispose();
    _ad = null;
    notifyListeners();
    unawaited(_load());
  }

  /// Delay before retrying after [failures] failed loads in a row.
  @visibleForTesting
  static Duration retryDelay(int failures) {
    const first = Duration(seconds: 15);
    const longest = Duration(minutes: 10);
    final seconds = first.inSeconds * math.pow(2, math.min(failures, 10));
    return Duration(seconds: math.min(seconds.toInt(), longest.inSeconds));
  }

  /// Shows the loaded ad. Returns true only if the reward was earned; false
  /// when no ad is ready, the player closed it early, or it failed to show.
  Future<bool> show() async {
    final ad = _ad;
    if (ad == null || _showing || _disposed) return false;
    _ad = null;
    _expiry?.cancel();
    _showing = true;
    notifyListeners();
    var earned = false;
    try {
      earned = await ad.show();
    } catch (error) {
      debugPrint('app_ads: show failed: $error');
    }
    _showing = false;
    if (_disposed) return earned;
    notifyListeners();
    unawaited(_load());
    return earned;
  }

  /// Shows Google's form to review or change ad consent.
  Future<void> showPrivacyOptions() async {
    try {
      await _backend.showPrivacyOptions();
    } catch (error) {
      debugPrint('app_ads: privacy options failed: $error');
    }
    await _refreshPrivacyOptions();
    // Consent given just now may allow ads that weren't allowed before.
    if (!_sdkReady && !_disposed) {
      try {
        if (await _backend.canRequestAds()) await _setUp();
      } catch (error) {
        debugPrint('app_ads: consent check failed: $error');
      }
    }
  }

  /// Coming back to the app is a good moment to retry: the network may be
  /// back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResumed();
  }

  @visibleForTesting
  void onResumed() {
    if (_disposed || _showing) return;
    if (!_sdkReady) {
      unawaited(_setUp());
    } else if (_ad == null && !_loading) {
      _failures = 0;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observeLifecycle && _started) {
      WidgetsBinding.instance.removeObserver(this);
    }
    _retry?.cancel();
    _expiry?.cancel();
    _ad?.dispose();
    _ad = null;
    super.dispose();
  }
}
