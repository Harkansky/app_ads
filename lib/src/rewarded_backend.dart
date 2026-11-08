import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// The calls [AdMobRewarded] makes to the ads SDK, behind an interface so its
/// logic (offline, retries, expiry, reward only when earned) can be tested
/// without the platform plugin.
abstract class RewardedBackend {
  /// Refreshes consent information and shows Google's consent form when the
  /// player still has to answer it (EEA, UK, Switzerland; on iPhone also the
  /// tracking explainer and Apple's prompt, if configured in AdMob).
  ///
  /// Returns whether ads may be requested. Offline, the refresh fails and the
  /// answer comes from the consent stored on a previous launch.
  Future<bool> gatherConsent({required bool debugEea});

  /// Whether the app must offer a way to change consent (Settings).
  Future<bool> privacyOptionsRequired();

  /// Shows Google's form to review or change consent.
  Future<void> showPrivacyOptions();

  /// Whether ads may be requested with the consent stored now.
  Future<bool> canRequestAds();

  /// Starts the ads SDK. Only called once ads may be requested.
  Future<void> initializeSdk();

  /// Loads one rewarded ad, or returns null when none could be loaded
  /// (offline, no fill, error).
  Future<LoadedRewardedAd?> load(String adUnitId);
}

/// A rewarded ad ready to be shown once.
abstract class LoadedRewardedAd {
  /// Shows the ad full screen. Completes when it is closed, with true only if
  /// the SDK reported that the reward was earned.
  Future<bool> show();

  /// Frees the ad without showing it.
  void dispose();
}

/// The real backend, over the official `google_mobile_ads` plugin.
class GoogleRewardedBackend implements RewardedBackend {
  const GoogleRewardedBackend();

  /// Longest wait for the consent refresh before carrying on with the
  /// stored consent (a slow network must not hold ads back forever).
  static const _consentTimeout = Duration(seconds: 20);

  @override
  Future<bool> gatherConsent({required bool debugEea}) async {
    final params = ConsentRequestParameters(
      consentDebugSettings: debugEea
          ? ConsentDebugSettings(
              debugGeography: DebugGeography.debugGeographyEea,
            )
          : null,
    );
    final updated = Completer<bool>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      params,
      () => updated.complete(true),
      (error) {
        debugPrint('app_ads: consent update failed: ${error.message}');
        updated.complete(false);
      },
    );
    final ok = await updated.future.timeout(
      _consentTimeout,
      onTimeout: () => false,
    );
    if (ok) {
      await ConsentForm.loadAndShowConsentFormIfRequired((error) {
        if (error != null) {
          debugPrint('app_ads: consent form: ${error.message}');
        }
      });
    }
    return ConsentInformation.instance.canRequestAds();
  }

  @override
  Future<bool> privacyOptionsRequired() async =>
      await ConsentInformation.instance.getPrivacyOptionsRequirementStatus() ==
      PrivacyOptionsRequirementStatus.required;

  @override
  Future<void> showPrivacyOptions() => ConsentForm.showPrivacyOptionsForm((
    error,
  ) {
    if (error != null) debugPrint('app_ads: privacy options: ${error.message}');
  });

  @override
  Future<bool> canRequestAds() => ConsentInformation.instance.canRequestAds();

  @override
  Future<void> initializeSdk() async {
    await MobileAds.instance.initialize();
  }

  @override
  Future<LoadedRewardedAd?> load(String adUnitId) {
    final result = Completer<LoadedRewardedAd?>();
    RewardedAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) => result.complete(_GoogleRewardedAd(ad)),
        onAdFailedToLoad: (error) {
          debugPrint('app_ads: rewarded ad failed to load: ${error.message}');
          result.complete(null);
        },
      ),
    );
    return result.future;
  }
}

class _GoogleRewardedAd implements LoadedRewardedAd {
  _GoogleRewardedAd(this._ad);

  final RewardedAd _ad;

  /// The reward callback can arrive just after the ad is closed on some
  /// devices: wait this long before deciding it wasn't earned.
  static const _rewardGrace = Duration(milliseconds: 500);

  @override
  Future<bool> show() async {
    final closed = Completer<bool>();
    var earned = false;
    _ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        Future<void>.delayed(earned ? Duration.zero : _rewardGrace, () {
          if (!closed.isCompleted) closed.complete(earned);
        });
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('app_ads: rewarded ad failed to show: ${error.message}');
        ad.dispose();
        if (!closed.isCompleted) closed.complete(false);
      },
    );
    await _ad.show(onUserEarnedReward: (ad, reward) => earned = true);
    return closed.future;
  }

  @override
  void dispose() => _ad.dispose();
}
