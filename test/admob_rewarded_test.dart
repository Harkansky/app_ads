import 'package:app_ads/app_ads.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted stand-in for the ads SDK.
class FakeBackend implements RewardedBackend {
  bool consent = true;
  bool online = true;
  bool privacyRequired = false;
  bool earnReward = true;
  int loads = 0;
  int sdkStarts = 0;
  int privacyFormsShown = 0;
  final shownAds = <FakeAd>[];
  final disposedAds = <FakeAd>[];

  @override
  Future<bool> gatherConsent({required bool debugEea}) async => consent;

  @override
  Future<bool> canRequestAds() async => consent;

  @override
  Future<bool> privacyOptionsRequired() async => privacyRequired;

  @override
  Future<void> showPrivacyOptions() async {
    privacyFormsShown++;
    consent = true;
  }

  @override
  Future<void> initializeSdk() async => sdkStarts++;

  @override
  Future<LoadedRewardedAd?> load(String adUnitId) async {
    loads++;
    return online ? FakeAd(this) : null;
  }
}

class FakeAd implements LoadedRewardedAd {
  FakeAd(this.backend);
  final FakeBackend backend;

  @override
  Future<bool> show() async {
    backend.shownAds.add(this);
    return backend.earnReward;
  }

  @override
  void dispose() => backend.disposedAds.add(this);
}

AdMobRewarded ads(
  FakeBackend backend, {
  Duration maxAge = const Duration(minutes: 55),
}) => AdMobRewarded(
  adUnitId: 'unit',
  backend: backend,
  maxAge: maxAge,
  observeLifecycle: false,
);

void main() {
  test('online: loads one ad, shows it, rewards, loads the next', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final rewarded = ads(backend)..init();
      async.flushMicrotasks();
      expect(backend.sdkStarts, 1);
      expect(rewarded.isReady, isTrue);
      expect(backend.loads, 1);

      bool? earned;
      rewarded.show().then((value) => earned = value);
      async.flushMicrotasks();
      expect(earned, isTrue);
      expect(backend.shownAds, hasLength(1));
      expect(backend.loads, 2, reason: 'next ad loads right after');
      expect(rewarded.isReady, isTrue);
    });
  });

  test('no reward when the player closes the ad early', () {
    fakeAsync((async) {
      final backend = FakeBackend()..earnReward = false;
      final rewarded = ads(backend)..init();
      async.flushMicrotasks();
      bool? earned;
      rewarded.show().then((value) => earned = value);
      async.flushMicrotasks();
      expect(earned, isFalse);
    });
  });

  test('offline: never ready, show returns false, retries with backoff', () {
    fakeAsync((async) {
      final backend = FakeBackend()..online = false;
      final rewarded = ads(backend)..init();
      async.flushMicrotasks();
      expect(rewarded.isReady, isFalse);
      expect(backend.loads, 1);

      bool? earned;
      rewarded.show().then((value) => earned = value);
      async.flushMicrotasks();
      expect(earned, isFalse);
      expect(backend.shownAds, isEmpty);

      async.elapse(const Duration(seconds: 15));
      expect(backend.loads, 2, reason: 'first retry after 15 s');
      async.elapse(const Duration(seconds: 29));
      expect(backend.loads, 2, reason: 'second retry waits 30 s');
      async.elapse(const Duration(seconds: 1));
      expect(backend.loads, 3);

      backend.online = true;
      async.elapse(const Duration(minutes: 1));
      expect(rewarded.isReady, isTrue);
    });
  });

  test('coming back to the app retries at once', () {
    fakeAsync((async) {
      final backend = FakeBackend()..online = false;
      final rewarded = ads(backend)..init();
      async.flushMicrotasks();
      backend.online = true;
      rewarded.onResumed();
      async.flushMicrotasks();
      expect(rewarded.isReady, isTrue);
    });
  });

  test('a stale ad is replaced', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final rewarded = ads(backend, maxAge: const Duration(minutes: 55))
        ..init();
      async.flushMicrotasks();
      expect(backend.loads, 1);
      async.elapse(const Duration(minutes: 55));
      expect(backend.disposedAds, hasLength(1));
      expect(backend.loads, 2);
      expect(rewarded.isReady, isTrue);
    });
  });

  test('without consent: no SDK, no ads; consent given later starts them', () {
    fakeAsync((async) {
      final backend = FakeBackend()
        ..consent = false
        ..privacyRequired = true;
      final rewarded = ads(backend)..init();
      async.flushMicrotasks();
      expect(backend.sdkStarts, 0);
      expect(backend.loads, 0);
      expect(rewarded.privacyOptionsRequired, isTrue);

      rewarded.showPrivacyOptions();
      async.flushMicrotasks();
      expect(backend.privacyFormsShown, 1);
      expect(backend.sdkStarts, 1);
      expect(rewarded.isReady, isTrue);
    });
  });

  test('dispose frees the loaded ad and stops retries', () {
    fakeAsync((async) {
      final backend = FakeBackend();
      final rewarded = ads(backend)..init();
      async.flushMicrotasks();
      rewarded.dispose();
      expect(backend.disposedAds, hasLength(1));
      async.elapse(const Duration(hours: 2));
      expect(backend.loads, 1);
    });
  });

  test('retry delay grows from 15 s and caps at 10 min', () {
    expect(AdMobRewarded.retryDelay(0), const Duration(seconds: 15));
    expect(AdMobRewarded.retryDelay(1), const Duration(seconds: 30));
    expect(AdMobRewarded.retryDelay(5), const Duration(minutes: 8));
    expect(AdMobRewarded.retryDelay(6), const Duration(minutes: 10));
    expect(AdMobRewarded.retryDelay(50), const Duration(minutes: 10));
  });
}
