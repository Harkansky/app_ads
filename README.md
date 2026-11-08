# app_ads

Rewarded ads ("watch an ad to continue") for apps built from app_template: Google AdMob through the official [`google_mobile_ads`](https://pub.dev/packages/google_mobile_ads) plugin, with Google's consent form (UMP). It never makes the app wait on the network.

Apps don't use this package directly. The template's `lib/ads.dart` adapts `AdMobRewarded` to app_core's `RewardedAds`, and the rest of the app only sees app_core types. That's what lets bootstrap remove ads from an app (`ads.enabled: false` in `app.config.yaml`) by deleting one dependency and swapping one file. This package deliberately doesn't depend on app_core, so the two are released independently.

## How it behaves

| Situation | What happens |
|---|---|
| First launch in the EEA, UK or Switzerland | Google's consent form shows, then (on iPhone, if configured in AdMob) the tracking explainer and Apple's "Allow tracking?" prompt. Needs the messages set up in AdMob > Privacy & messaging. |
| Online, consent OK | The SDK starts and one rewarded ad loads in the background. `isReady` turns true. |
| Offline | Nothing loads, `isReady` stays false, nothing is sent. Loading is retried after 15 s, 30 s, 1 min… up to every 10 min, and right away when the app comes back to the foreground. |
| Player watches the ad | `show()` returns true only if AdMob reported the reward as earned, then the next ad loads. |
| Player closes it early / it fails | `show()` returns false. |
| Ad loaded for 55 min | It's replaced by a fresh one (AdMob ads go stale). |
| Consent required here | `privacyOptionsRequired` is true; app_core's Settings screen then shows "Privacy settings", which calls `showPrivacyOptions()`. |

Debug builds must use `AdMobTestIds` (Google's public test units): tapping your own real ads can get the AdMob account suspended. The template does this automatically.

## API

```dart
final ads = AdMobRewarded(adUnitId: AdMobTestIds.iosRewarded);
unawaited(ads.init());          // consent + SDK + first load, in the background
if (ads.isReady) {
  final earned = await ads.show();
}
if (ads.privacyOptionsRequired) await ads.showPrivacyOptions();
```

The native app ID (`GADApplicationIdentifier` in `Info.plist`, `com.google.android.gms.ads.APPLICATION_ID` in `AndroidManifest.xml`) is written by the template's bootstrap from `app.config.yaml`. Without it the app crashes at launch.

## Develop and release

```bash
flutter pub get && flutter analyze && flutter test
```

The SDK sits behind `RewardedBackend`, so the logic (offline, retries, expiry, reward only when earned, consent) is tested with a fake backend and fake time, without devices.

Release like app_core: set `version:` in `pubspec.yaml`, commit, push and wait for CI, `git tag vX.Y.Z && git push --tags`, then bump `ref:` under `app_ads` in app_template and each app.

Keep this repo **public** so app CI can fetch it without a token.
