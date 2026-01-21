import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;
import 'dart:math' as math;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dairyhunter/pushdairy.dart' hide LuckyHunterNeonLoader;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodChannel, SystemChrome, SystemUiOverlayStyle, MethodCall;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

import 'luckdairy.dart';

// ЗАМЕНИ на твои реальные файлы, если имена другие
// если нужно, можно удалить, если не используется.

// ============================================================================
// Константы
// ============================================================================

const String goldLuxuryLoadedOnceKey = 'loaded_once';
const String goldLuxuryStatEndpoint = 'https://apisrc.diaryh.online/ stat';
const String goldLuxuryCachedFcmKey = 'cached_fcm';
const String goldLuxuryCachedDeepKey = 'cached_deep_push_uri';

// ============================================================================
// Лёгкие сервисы
// ============================================================================

class LuckyHunterLoggerService {
  static final LuckyHunterLoggerService sharedInstance =
  LuckyHunterLoggerService._internalConstructor();

  LuckyHunterLoggerService._internalConstructor();

  factory LuckyHunterLoggerService() => sharedInstance;

  final Connectivity luckyHunterConnectivity = Connectivity();

  void luckyHunterLogInfo(Object message) => debugPrint('[I] $message');
  void luckyHunterLogWarn(Object message) => debugPrint('[W] $message');
  void luckyHunterLogError(Object message) => debugPrint('[E] $message');
}

// ============================================================================
// Сеть/данные
// ============================================================================

class LuckyHunterNetworkService {
  final LuckyHunterLoggerService luckyHunterLogger = LuckyHunterLoggerService();

  Future<bool> luckyHunterIsOnline() async {
    final List<ConnectivityResult> luckyHunterResults =
    (await luckyHunterLogger.luckyHunterConnectivity.checkConnectivity()) as List<ConnectivityResult>;
    return luckyHunterResults.isNotEmpty &&
        !luckyHunterResults.contains(ConnectivityResult.none);
  }

  Future<void> luckyHunterPostJson(
      String url,
      Map<String, dynamic> data,
      ) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (error) {
      luckyHunterLogger.luckyHunterLogError('postJson error: $error');
    }
  }
}

// ============================================================================
// Досье устройства
// ============================================================================

class LuckyHunterDeviceProfile {
  String? luckyHunterDeviceId;
  String? luckyHunterSessionId = 'roulette-one-off';
  String? luckyHunterPlatformName;
  String? luckyHunterOsVersion;
  String? luckyHunterAppVersion;
  String? luckyHunterLanguageCode;
  String? luckyHunterTimezoneName;
  bool luckyHunterPushEnabled = true;

  Future<void> luckyHunterInitialize() async {
    final DeviceInfoPlugin luckyHunterDeviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo luckyHunterAndroidInfo =
      await luckyHunterDeviceInfoPlugin.androidInfo;
      luckyHunterDeviceId = luckyHunterAndroidInfo.id;
      luckyHunterPlatformName = 'android';
      luckyHunterOsVersion = luckyHunterAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo luckyHunterIosInfo =
      await luckyHunterDeviceInfoPlugin.iosInfo;
      luckyHunterDeviceId = luckyHunterIosInfo.identifierForVendor;
      luckyHunterPlatformName = 'ios';
      luckyHunterOsVersion = luckyHunterIosInfo.systemVersion;
    }

    final PackageInfo luckyHunterPackageInfo =
    await PackageInfo.fromPlatform();
    luckyHunterAppVersion = luckyHunterPackageInfo.version;
    luckyHunterLanguageCode = Platform.localeName.split('_').first;
    luckyHunterTimezoneName = tz_zone.local.name;
    luckyHunterSessionId =
    'roulette-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> luckyHunterToMap({String? fcmToken}) => {
    'fcm_token': fcmToken ?? 'missing_token',
    'device_id': luckyHunterDeviceId ?? 'missing_id',
    'app_name': 'diaryh',
    'instance_id': luckyHunterSessionId ?? 'missing_session',
    'platform': luckyHunterPlatformName ?? 'missing_system',
    'os_version': luckyHunterOsVersion ?? 'missing_build',
    'app_version': luckyHunterAppVersion ?? 'missing_app',
    'language': luckyHunterLanguageCode ?? 'en',
    'timezone': luckyHunterTimezoneName ?? 'UTC',
    'push_enabled': luckyHunterPushEnabled,
  };
}

// ============================================================================
// AppsFlyer
// ============================================================================

class LuckyHunterAnalyticsSpyService {
  appsflyer_core.AppsFlyerOptions? luckyHunterAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? luckyHunterAppsFlyerSdk;

  String luckyHunterAppsFlyerUid = '';
  String luckyHunterAppsFlyerData = '';

  void luckyHunterStartTracking({VoidCallback? onUpdate}) {
    final appsflyer_core.AppsFlyerOptions luckyHunterConfig =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6757854265',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    luckyHunterAppsFlyerOptions = luckyHunterConfig;
    luckyHunterAppsFlyerSdk = appsflyer_core.AppsflyerSdk(luckyHunterConfig);

    luckyHunterAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    luckyHunterAppsFlyerSdk?.startSDK(
      onSuccess: () =>
          LuckyHunterLoggerService().luckyHunterLogInfo('GoldenLuxuryAnalyticsSpy started'),
      onError: (code, msg) => LuckyHunterLoggerService()
          .luckyHunterLogError('GoldenLuxuryAnalyticsSpy error $code: $msg'),
    );

    luckyHunterAppsFlyerSdk?.onInstallConversionData((value) {
      luckyHunterAppsFlyerData = value.toString();
      onUpdate?.call();
    });

    luckyHunterAppsFlyerSdk?.getAppsFlyerUID().then((value) {
      luckyHunterAppsFlyerUid = value.toString();
      onUpdate?.call();
    });
  }
}



// ============================================================================
// FCM фоновые крики
// ============================================================================

@pragma('vm:entry-point')
Future<void> luckyHunterFcmBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  LuckyHunterLoggerService()
      .luckyHunterLogInfo('bg-fcm: ${message.messageId}');
  LuckyHunterLoggerService()
      .luckyHunterLogInfo('bg-data: ${message.data}');

  final dynamic luckyHunterLink = message.data['uri'];
  if (luckyHunterLink != null) {
    try {
      final SharedPreferences luckyHunterPrefs =
      await SharedPreferences.getInstance();
      await luckyHunterPrefs.setString(
        goldLuxuryCachedDeepKey,
        luckyHunterLink.toString(),
      );
    } catch (e) {
      LuckyHunterLoggerService()
          .luckyHunterLogError('bg-fcm save deep failed: $e');
    }
  }
}

// ============================================================================
// FCM Bridge
// ============================================================================

class LuckyHunterFcmBridge {
  final LuckyHunterLoggerService luckyHunterLogger = LuckyHunterLoggerService();
  String? luckyHunterToken;
  final List<void Function(String)> luckyHunterTokenWaiters =
  <void Function(String)>[];

  String? get luckyHunterFcmToken => luckyHunterToken;

  LuckyHunterFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setToken') {
        final String luckyHunterTokenString = call.arguments as String;
        if (luckyHunterTokenString.isNotEmpty) {
          luckyHunterSetToken(luckyHunterTokenString);
        }
      }
    });

    luckyHunterRestoreToken();
  }

  Future<void> luckyHunterRestoreToken() async {
    try {
      final SharedPreferences luckyHunterPrefs =
      await SharedPreferences.getInstance();
      final String? luckyHunterCachedToken =
      luckyHunterPrefs.getString(goldLuxuryCachedFcmKey);
      if (luckyHunterCachedToken != null &&
          luckyHunterCachedToken.isNotEmpty) {
        luckyHunterSetToken(luckyHunterCachedToken, notify: false);
      }
    } catch (_) {}
  }

  Future<void> luckyHunterPersistToken(String newToken) async {
    try {
      final SharedPreferences luckyHunterPrefs =
      await SharedPreferences.getInstance();
      await luckyHunterPrefs.setString(goldLuxuryCachedFcmKey, newToken);
    } catch (_) {}
  }

  void luckyHunterSetToken(
      String newToken, {
        bool notify = true,
      }) {
    luckyHunterToken = newToken;
    luckyHunterPersistToken(newToken);
    if (notify) {
      for (final void Function(String) luckyHunterCallback
      in List<void Function(String)>.from(luckyHunterTokenWaiters)) {
        try {
          luckyHunterCallback(newToken);
        } catch (error) {
          luckyHunterLogger.luckyHunterLogWarn('fcm waiter error: $error');
        }
      }
      luckyHunterTokenWaiters.clear();
    }
  }

  Future<void> luckyHunterWaitForToken(
      Function(String token) luckyHunterOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((luckyHunterToken ?? '').isNotEmpty) {
        luckyHunterOnToken(luckyHunterToken!);
        return;
      }

      luckyHunterTokenWaiters.add(luckyHunterOnToken);
    } catch (error) {
      luckyHunterLogger.luckyHunterLogError('waitToken error: $error');
    }
  }
}

// ============================================================================
// Splash / Hall
// ============================================================================

class LuckyHunterHall extends StatefulWidget {
  const LuckyHunterHall({Key? key}) : super(key: key);

  @override
  State<LuckyHunterHall> createState() => _LuckyHunterHallState();
}

class _LuckyHunterHallState extends State<LuckyHunterHall> {
  final LuckyHunterFcmBridge luckyHunterFcmBridge = LuckyHunterFcmBridge();
  bool luckyHunterNavigatedOnce = false;
  Timer? luckyHunterFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    luckyHunterFcmBridge.luckyHunterWaitForToken((String luckyHunterToken) {
      luckyHunterGoToHarbor(luckyHunterToken);
    });

    luckyHunterFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => luckyHunterGoToHarbor(''),
    );
  }

  void luckyHunterGoToHarbor(String luckyHunterSignal) {
    if (luckyHunterNavigatedOnce) return;
    luckyHunterNavigatedOnce = true;
    luckyHunterFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext context) =>
            LuckyHunterHarbor(luckyHunterSignal: luckyHunterSignal),
      ),
    );
  }

  @override
  void dispose() {
    luckyHunterFallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: LuckyHunterNeonLoader(),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class LuckyHunterBosunViewModel {
  final LuckyHunterDeviceProfile luckyHunterDeviceProfile;
  final LuckyHunterAnalyticsSpyService luckyHunterAnalyticsSpy;

  LuckyHunterBosunViewModel({
    required this.luckyHunterDeviceProfile,
    required this.luckyHunterAnalyticsSpy,
  });

  Map<String, dynamic> luckyHunterDeviceMap(String? fcmToken) =>
      luckyHunterDeviceProfile.luckyHunterToMap(fcmToken: fcmToken);

  Map<String, dynamic> luckyHunterAppsFlyerPayload(
      String? token, {
        String? deepLink,
      }) =>
      {
        'content': {
          'af_data': luckyHunterAnalyticsSpy.luckyHunterAppsFlyerData,
          'af_id': luckyHunterAnalyticsSpy.luckyHunterAppsFlyerUid,
          'fb_app_name': 'diaryh',
          'app_name': 'diaryh',
          'deep': deepLink,
          'bundle_identifier': 'com.hunterdiaryluck.dairyhunter',
          'app_version': '1.0.0',
          'apple_id': '6757854265',
          'fcm_token': token ?? 'no_token',
          'device_id':
          luckyHunterDeviceProfile.luckyHunterDeviceId ?? 'no_device',
          'instance_id':
          luckyHunterDeviceProfile.luckyHunterSessionId ?? 'no_instance',
          'platform':
          luckyHunterDeviceProfile.luckyHunterPlatformName ?? 'no_type',
          'os_version':
          luckyHunterDeviceProfile.luckyHunterOsVersion ?? 'no_os',
          'app_version':
          luckyHunterDeviceProfile.luckyHunterAppVersion ?? 'no_app',
          'language':
          luckyHunterDeviceProfile.luckyHunterLanguageCode ?? 'en',
          'timezone':
          luckyHunterDeviceProfile.luckyHunterTimezoneName ?? 'UTC',
          'push_enabled':
          luckyHunterDeviceProfile.luckyHunterPushEnabled,
          'useruid': luckyHunterAnalyticsSpy.luckyHunterAppsFlyerUid,
        },
      };
}

class LuckyHunterCourierService {
  final LuckyHunterBosunViewModel luckyHunterBosun;
  final InAppWebViewController Function() luckyHunterGetWebViewController;

  LuckyHunterCourierService({
    required this.luckyHunterBosun,
    required this.luckyHunterGetWebViewController,
  });

  Future<void> luckyHunterPutDeviceToLocalStorage(String? token) async {
    final Map<String, dynamic> luckyHunterMap =
    luckyHunterBosun.luckyHunterDeviceMap(token);
    await luckyHunterGetWebViewController().evaluateJavascript(
      source:
      "localStorage.setItem('app_data', JSON.stringify(${jsonEncode(luckyHunterMap)}));",
    );
  }

  Future<void> luckyHunterSendRawToPage(
      String? token, {
        String? deepLink,
      }) async {
    final Map<String, dynamic> luckyHunterPayload =
    luckyHunterBosun.luckyHunterAppsFlyerPayload(
      token,
      deepLink: deepLink,
    );
    final String luckyHunterJsonString = jsonEncode(luckyHunterPayload);

    print('load stry$luckyHunterJsonString');
    LuckyHunterLoggerService()
        .luckyHunterLogInfo('SendRawData: $luckyHunterJsonString');

    await luckyHunterGetWebViewController().evaluateJavascript(
      source: 'sendRawData(${jsonEncode(luckyHunterJsonString)});',
    );
  }
}

// ============================================================================
// Переходы/статистика
// ============================================================================

Future<String> luckyHunterResolveFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient luckyHunterHttpClient = HttpClient();

  try {
    Uri luckyHunterCurrentUri = Uri.parse(startUrl);

    for (int i = 0; i < maxHops; i++) {
      final HttpClientRequest luckyHunterRequest =
      await luckyHunterHttpClient.getUrl(luckyHunterCurrentUri);
      luckyHunterRequest.followRedirects = false;
      final HttpClientResponse luckyHunterResponse =
      await luckyHunterRequest.close();

      if (luckyHunterResponse.isRedirect) {
        final String? luckyHunterLocationHeader =
        luckyHunterResponse.headers.value(HttpHeaders.locationHeader);
        if (luckyHunterLocationHeader == null ||
            luckyHunterLocationHeader.isEmpty) {
          break;
        }

        final Uri luckyHunterNextUri = Uri.parse(luckyHunterLocationHeader);
        luckyHunterCurrentUri = luckyHunterNextUri.hasScheme
            ? luckyHunterNextUri
            : luckyHunterCurrentUri.resolveUri(luckyHunterNextUri);
        continue;
      }

      return luckyHunterCurrentUri.toString();
    }

    return luckyHunterCurrentUri.toString();
  } catch (error) {
    debugPrint('goldenLuxuryResolveFinalUrl error: $error');
    return startUrl;
  } finally {
    luckyHunterHttpClient.close(force: true);
  }
}

Future<void> luckyHunterPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final String luckyHunterResolvedUrl =
    await luckyHunterResolveFinalUrl(url);

    final Map<String, dynamic> luckyHunterPayload = <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': luckyHunterResolvedUrl,
      'appleID': '6757854265',
      'open_count': '$appSid/$timeStart',
    };

    debugPrint('goldenLuxuryStat $luckyHunterPayload');

    final http.Response luckyHunterResponse = await http.post(
      Uri.parse('$goldLuxuryStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(luckyHunterPayload),
    );

    debugPrint(
        'goldenLuxuryStat resp=${luckyHunterResponse.statusCode} body=${luckyHunterResponse.body}');
  } catch (error) {
    debugPrint('goldenLuxuryPostStat error: $error');
  }
}

// ============================================================================
// Главный WebView — Harbor
// ============================================================================

class LuckyHunterHarbor extends StatefulWidget {
  final String? luckyHunterSignal;

  const LuckyHunterHarbor({super.key, required this.luckyHunterSignal});

  @override
  State<LuckyHunterHarbor> createState() => _LuckyHunterHarborState();
}

class _LuckyHunterHarborState extends State<LuckyHunterHarbor>
    with WidgetsBindingObserver {
  late InAppWebViewController luckyHunterWebViewController;
  final String luckyHunterHomeUrl = 'https://apisrc.diaryh.online/';

  int luckyHunterWebViewKeyCounter = 0;
  DateTime? luckyHunterSleepAt;
  bool luckyHunterVeilVisible = false;
  double luckyHunterWarmProgress = 0.0;
  late Timer luckyHunterWarmTimer;
  final int luckyHunterWarmSeconds = 6;
  bool luckyHunterCoverVisible = true;

  bool luckyHunterLoadedOnceSent = false;
  int? luckyHunterFirstPageTimestamp;

  LuckyHunterCourierService? luckyHunterCourier;
  LuckyHunterBosunViewModel? luckyHunterBosunViewModel;

  String luckyHunterCurrentUrl = '';
  int luckyHunterStartLoadTimestamp = 0;

  final LuckyHunterDeviceProfile luckyHunterDeviceProfile =
  LuckyHunterDeviceProfile();
  final LuckyHunterAnalyticsSpyService luckyHunterAnalyticsSpyService =
  LuckyHunterAnalyticsSpyService();
  bool luckyHunterUseSafeArea = false;

  final Set<String> luckyHunterSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  final Set<String> luckyHunterExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  String? luckyHunterDeepLinkFromPush;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    luckyHunterFirstPageTimestamp =
        DateTime.now().millisecondsSinceEpoch;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          luckyHunterCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        luckyHunterVeilVisible = true;
      });
    });

    luckyHunterBootHarbor();
  }

  Future<void> luckyHunterLoadLoadedFlag() async {
    final SharedPreferences luckyHunterPrefs =
    await SharedPreferences.getInstance();
    luckyHunterLoadedOnceSent =
        luckyHunterPrefs.getBool(goldLuxuryLoadedOnceKey) ?? false;
  }

  Future<void> luckyHunterSaveLoadedFlag() async {
    final SharedPreferences luckyHunterPrefs =
    await SharedPreferences.getInstance();
    await luckyHunterPrefs.setBool(goldLuxuryLoadedOnceKey, true);
    luckyHunterLoadedOnceSent = true;
  }

  Future<void> luckyHunterLoadCachedDeep() async {
    try {
      final SharedPreferences luckyHunterPrefs =
      await SharedPreferences.getInstance();
      final String? luckyHunterCached =
      luckyHunterPrefs.getString(goldLuxuryCachedDeepKey);
      if ((luckyHunterCached ?? '').isNotEmpty) {
        luckyHunterDeepLinkFromPush = luckyHunterCached;
      }
    } catch (_) {}
  }

  Future<void> luckyHunterSaveCachedDeep(String uri) async {
    try {
      final SharedPreferences luckyHunterPrefs =
      await SharedPreferences.getInstance();
      await luckyHunterPrefs.setString(goldLuxuryCachedDeepKey, uri);
    } catch (_) {}
  }

  Future<void> luckyHunterSendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (luckyHunterLoadedOnceSent) {
      debugPrint('Loaded already sent, skip');
      return;
    }

    final int luckyHunterNow =
        DateTime.now().millisecondsSinceEpoch;

    await luckyHunterPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: luckyHunterNow,
      url: url,
      appSid: luckyHunterAnalyticsSpyService.luckyHunterAppsFlyerUid,
      firstPageLoadTs: luckyHunterFirstPageTimestamp,
    );

    await luckyHunterSaveLoadedFlag();
  }

  void luckyHunterBootHarbor() {
    luckyHunterStartWarmProgress();
    luckyHunterWireFcmHandlers();
    luckyHunterAnalyticsSpyService.luckyHunterStartTracking(
      onUpdate: () => setState(() {}),
    );
    luckyHunterBindNotificationTap();
    luckyHunterPrepareDeviceProfile();

    Future<void>.delayed(const Duration(seconds: 6), () async {
      await luckyHunterPushDeviceInfo();
      await luckyHunterPushAppsFlyerData();
    });
  }

  void luckyHunterWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage luckyHunterMessage) async {
      final dynamic luckyHunterLink = luckyHunterMessage.data['uri'];
      if (luckyHunterLink != null) {
        final String luckyHunterUri = luckyHunterLink.toString();
        luckyHunterDeepLinkFromPush = luckyHunterUri;
        await luckyHunterSaveCachedDeep(luckyHunterUri);
        luckyHunterNavigateToUri(luckyHunterUri);
      } else {
        luckyHunterResetHomeAfterDelay();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage luckyHunterMessage) async {
      final dynamic luckyHunterLink = luckyHunterMessage.data['uri'];
      if (luckyHunterLink != null) {
        final String luckyHunterUri = luckyHunterLink.toString();
        luckyHunterDeepLinkFromPush = luckyHunterUri;
        await luckyHunterSaveCachedDeep(luckyHunterUri);
        luckyHunterNavigateToUri(luckyHunterUri);
      } else {
        luckyHunterResetHomeAfterDelay();
      }
    });
  }

  void luckyHunterBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> luckyHunterPayload =
        Map<String, dynamic>.from(call.arguments);
        if (luckyHunterPayload['uri'] != null &&
            !luckyHunterPayload['uri']
                .toString()
                .contains('Нет URI')) {
          final String luckyHunterUri =
          luckyHunterPayload['uri'].toString();
          luckyHunterDeepLinkFromPush = luckyHunterUri;
          await luckyHunterSaveCachedDeep(luckyHunterUri);

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) =>
                  LuckyHunterTableView(luckyHunterUri),
            ),
                (Route<dynamic> route) => false,
          );
        }
      }
    });
  }

  Future<void> luckyHunterPrepareDeviceProfile() async {
    try {
      await luckyHunterDeviceProfile.luckyHunterInitialize();
      await luckyHunterRequestPushPermissions();

      await luckyHunterLoadLoadedFlag();
      await luckyHunterLoadCachedDeep();

      luckyHunterBosunViewModel = LuckyHunterBosunViewModel(
        luckyHunterDeviceProfile: luckyHunterDeviceProfile,
        luckyHunterAnalyticsSpy: luckyHunterAnalyticsSpyService,
      );

      luckyHunterCourier = LuckyHunterCourierService(
        luckyHunterBosun: luckyHunterBosunViewModel!,
        luckyHunterGetWebViewController: () => luckyHunterWebViewController,
      );
    } catch (error) {
      LuckyHunterLoggerService()
          .luckyHunterLogError('prepareDeviceProfile fail: $error');
    }
  }

  Future<void> luckyHunterRequestPushPermissions() async {
    final FirebaseMessaging luckyHunterMessaging =
        FirebaseMessaging.instance;
    await luckyHunterMessaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  void luckyHunterNavigateToUri(String link) async {
    try {
      await luckyHunterWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(link)),
      );
    } catch (error) {
      LuckyHunterLoggerService()
          .luckyHunterLogError('navigate error: $error');
    }
  }

  void luckyHunterResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        luckyHunterWebViewController.loadUrl(
          urlRequest: URLRequest(url: WebUri(luckyHunterHomeUrl)),
        );
      } catch (_) {}
    });
  }

  Future<void> luckyHunterPushDeviceInfo() async {
    LuckyHunterLoggerService()
        .luckyHunterLogInfo('TOKEN ship ${widget.luckyHunterSignal}');
    try {
      await luckyHunterCourier?.luckyHunterPutDeviceToLocalStorage(
        widget.luckyHunterSignal,
      );
    } catch (error) {
      LuckyHunterLoggerService()
          .luckyHunterLogError('pushDeviceInfo error: $error');
    }
  }

  Future<void> luckyHunterPushAppsFlyerData() async {
    try {
      await luckyHunterCourier?.luckyHunterSendRawToPage(
        widget.luckyHunterSignal,
        deepLink: luckyHunterDeepLinkFromPush,
      );
    } catch (error) {
      LuckyHunterLoggerService()
          .luckyHunterLogError('pushAppsFlyerData error: $error');
    }
  }

  void luckyHunterStartWarmProgress() {
    int luckyHunterTick = 0;
    luckyHunterWarmProgress = 0.0;

    luckyHunterWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
          if (!mounted) return;

          setState(() {
            luckyHunterTick++;
            luckyHunterWarmProgress =
                luckyHunterTick / (luckyHunterWarmSeconds * 10);

            if (luckyHunterWarmProgress >= 1.0) {
              luckyHunterWarmProgress = 1.0;
              luckyHunterWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      luckyHunterSleepAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && luckyHunterSleepAt != null) {
        final DateTime luckyHunterNow = DateTime.now();
        final Duration luckyHunterDrift =
        luckyHunterNow.difference(luckyHunterSleepAt!);

        if (luckyHunterDrift > const Duration(minutes: 25)) {
          luckyHunterReboardHarbor();
        }
      }
      luckyHunterSleepAt = null;
    }
  }

  void luckyHunterReboardHarbor() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              LuckyHunterHarbor(luckyHunterSignal: widget.luckyHunterSignal),
        ),
            (Route<dynamic> route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    luckyHunterWarmTimer.cancel();
    super.dispose();
  }

  bool luckyHunterIsBareEmail(Uri uri) {
    final String luckyHunterScheme = uri.scheme;
    if (luckyHunterScheme.isNotEmpty) return false;
    final String luckyHunterRaw = uri.toString();
    return luckyHunterRaw.contains('@') && !luckyHunterRaw.contains(' ');
  }

  Uri luckyHunterToMailto(Uri uri) {
    final String luckyHunterFull = uri.toString();
    final List<String> luckyHunterParts = luckyHunterFull.split('?');
    final String luckyHunterEmail = luckyHunterParts.first;
    final Map<String, String> luckyHunterQueryParams =
    luckyHunterParts.length > 1
        ? Uri.splitQueryString(luckyHunterParts[1])
        : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: luckyHunterEmail,
      queryParameters:
      luckyHunterQueryParams.isEmpty ? null : luckyHunterQueryParams,
    );
  }

  bool luckyHunterIsPlatformLink(Uri uri) {
    final String luckyHunterScheme = uri.scheme.toLowerCase();
    if (luckyHunterSpecialSchemes.contains(luckyHunterScheme)) {
      return true;
    }

    if (luckyHunterScheme == 'http' || luckyHunterScheme == 'https') {
      final String luckyHunterHost = uri.host.toLowerCase();

      if (luckyHunterExternalHosts.contains(luckyHunterHost)) {
        return true;
      }

      if (luckyHunterHost.endsWith('t.me')) return true;
      if (luckyHunterHost.endsWith('wa.me')) return true;
      if (luckyHunterHost.endsWith('m.me')) return true;
      if (luckyHunterHost.endsWith('signal.me')) return true;
      if (luckyHunterHost.endsWith('facebook.com')) return true;
      if (luckyHunterHost.endsWith('instagram.com')) return true;
      if (luckyHunterHost.endsWith('twitter.com')) return true;
      if (luckyHunterHost.endsWith('x.com')) return true;
    }

    return false;
  }

  String luckyHunterDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri luckyHunterHttpizePlatformUri(Uri uri) {
    final String luckyHunterScheme = uri.scheme.toLowerCase();

    if (luckyHunterScheme == 'tg' || luckyHunterScheme == 'telegram') {
      final Map<String, String> luckyHunterQp = uri.queryParameters;
      final String? luckyHunterDomain = luckyHunterQp['domain'];

      if (luckyHunterDomain != null && luckyHunterDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$luckyHunterDomain',
          <String, String>{
            if (luckyHunterQp['start'] != null) 'start': luckyHunterQp['start']!,
          },
        );
      }

      final String luckyHunterPath =
      uri.path.isNotEmpty ? uri.path : '';

      return Uri.https(
        't.me',
        '/$luckyHunterPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if ((luckyHunterScheme == 'http' || luckyHunterScheme == 'https') &&
        uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (luckyHunterScheme == 'viber') {
      return uri;
    }

    if (luckyHunterScheme == 'whatsapp') {
      final Map<String, String> luckyHunterQp = uri.queryParameters;
      final String? luckyHunterPhone = luckyHunterQp['phone'];
      final String? luckyHunterText = luckyHunterQp['text'];

      if (luckyHunterPhone != null && luckyHunterPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${luckyHunterDigitsOnly(luckyHunterPhone)}',
          <String, String>{
            if (luckyHunterText != null && luckyHunterText.isNotEmpty)
              'text': luckyHunterText,
          },
        );
      }

      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (luckyHunterText != null && luckyHunterText.isNotEmpty)
            'text': luckyHunterText,
        },
      );
    }

    if ((luckyHunterScheme == 'http' || luckyHunterScheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') ||
            uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (luckyHunterScheme == 'skype') {
      return uri;
    }

    if (luckyHunterScheme == 'fb-messenger') {
      final String luckyHunterPath = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.join('/')
          : '';
      final Map<String, String> luckyHunterQp = uri.queryParameters;

      final String luckyHunterId =
          luckyHunterQp['id'] ?? luckyHunterQp['user'] ?? luckyHunterPath;

      if (luckyHunterId.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$luckyHunterId',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (luckyHunterScheme == 'sgnl') {
      final Map<String, String> luckyHunterQp = uri.queryParameters;
      final String? luckyHunterPhone = luckyHunterQp['phone'];
      final String? luckyHunterUsername = luckyHunterQp['username'];

      if (luckyHunterPhone != null && luckyHunterPhone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${luckyHunterDigitsOnly(luckyHunterPhone)}',
        );
      }

      if (luckyHunterUsername != null && luckyHunterUsername.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$luckyHunterUsername',
        );
      }

      final String luckyHunterPath = uri.pathSegments.join('/');
      if (luckyHunterPath.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$luckyHunterPath',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return uri;
    }

    if (luckyHunterScheme == 'tel') {
      return Uri.parse('tel:${luckyHunterDigitsOnly(uri.path)}');
    }

    if (luckyHunterScheme == 'mailto') {
      return uri;
    }

    if (luckyHunterScheme == 'bnl') {
      final String luckyHunterNewPath =
      uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        'bnl.com',
        '/$luckyHunterNewPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    return uri;
  }

  Future<bool> luckyHunterOpenMailWeb(Uri mailto) async {
    final Uri luckyHunterGmailUri =
    luckyHunterGmailizeMailto(mailto);
    return await luckyHunterOpenWeb(luckyHunterGmailUri);
  }

  Uri luckyHunterGmailizeMailto(Uri mailUri) {
    final Map<String, String> luckyHunterQueryParams =
        mailUri.queryParameters;

    final Map<String, String> luckyHunterParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((luckyHunterQueryParams['subject'] ?? '').isNotEmpty)
        'su': luckyHunterQueryParams['subject']!,
      if ((luckyHunterQueryParams['body'] ?? '').isNotEmpty)
        'body': luckyHunterQueryParams['body']!,
      if ((luckyHunterQueryParams['cc'] ?? '').isNotEmpty)
        'cc': luckyHunterQueryParams['cc']!,
      if ((luckyHunterQueryParams['bcc'] ?? '').isNotEmpty)
        'bcc': luckyHunterQueryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', luckyHunterParams);
  }

  Future<bool> luckyHunterOpenWeb(Uri uri) async {
    try {
      if (await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }

      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      debugPrint('openInAppBrowser error: $error; url=$uri');
      try {
        return await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> luckyHunterOpenExternal(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      debugPrint('openExternal error: $error; url=$uri');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    luckyHunterBindNotificationTap();

    Widget luckyHunterContent = Stack(
      children: <Widget>[
        if (luckyHunterCoverVisible)
          const LuckyHunterNeonLoader()
        else
          Container(
            color: Colors.black,
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  key: ValueKey<int>(luckyHunterWebViewKeyCounter),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    disableDefaultErrorPage: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsInlineMediaPlayback: true,
                    allowsPictureInPictureMediaPlayback: true,
                    useOnDownloadStart: true,
                    javaScriptCanOpenWindowsAutomatically: true,
                    useShouldOverrideUrlLoading: true,
                    supportMultipleWindows: true,
                    transparentBackground: true,
                  ),
                  initialUrlRequest: URLRequest(
                    url: WebUri(luckyHunterHomeUrl),
                  ),
                  onWebViewCreated:
                      (InAppWebViewController controller) {
                    luckyHunterWebViewController = controller;

                    luckyHunterBosunViewModel ??= LuckyHunterBosunViewModel(
                      luckyHunterDeviceProfile: luckyHunterDeviceProfile,
                      luckyHunterAnalyticsSpy:
                      luckyHunterAnalyticsSpyService,
                    );

                    luckyHunterCourier ??= LuckyHunterCourierService(
                      luckyHunterBosun: luckyHunterBosunViewModel!,
                      luckyHunterGetWebViewController: () =>
                      luckyHunterWebViewController,
                    );

                    luckyHunterWebViewController.addJavaScriptHandler(
                      handlerName: 'onServerResponse',
                      callback: (List<dynamic> args) {
                        try {
                          if (args.isNotEmpty && args[0] is Map) {
                            final dynamic luckyHunterRaw =
                            args[0]['savedata'];
                            final String luckyHunterSavedata =
                                luckyHunterRaw?.toString() ?? '';

                            print("Server responseDD: $luckyHunterSavedata");

                            if (luckyHunterSavedata == "false") {
                              Navigator.pushReplacement<void, void>(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (BuildContext context) =>
                                  LuckyHunterHelpLite(),
                                ),
                              );
                            } else if (luckyHunterSavedata == "true") {}
                          }
                        } catch (_) {}

                        if (args.isEmpty) {
                          return null;
                        }

                        try {
                          return args.reduce(
                                (dynamic current, dynamic next) =>
                            current + next,
                          );
                        } catch (_) {
                          return args.first;
                        }
                      },
                    );
                  },
                  onLoadStart: (
                      InAppWebViewController controller,
                      Uri? uri,
                      ) async {
                    setState(() {
                      luckyHunterStartLoadTimestamp =
                          DateTime.now().millisecondsSinceEpoch;
                    });

                    final Uri? luckyHunterViewUri = uri;
                    if (luckyHunterViewUri != null) {
                      if (luckyHunterIsBareEmail(luckyHunterViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        final Uri luckyHunterMailto =
                        luckyHunterToMailto(luckyHunterViewUri);
                        await luckyHunterOpenMailWeb(luckyHunterMailto);
                        return;
                      }

                      final String luckyHunterScheme =
                      luckyHunterViewUri.scheme.toLowerCase();
                      if (luckyHunterScheme != 'http' &&
                          luckyHunterScheme != 'https') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                      }
                    }
                  },
                  onLoadError: (
                      InAppWebViewController controller,
                      Uri? uri,
                      int code,
                      String message,
                      ) async {
                    final int luckyHunterNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String luckyHunterEvent =
                        'InAppWebViewError(code=$code, message=$message)';

                    await luckyHunterPostStat(
                      event: luckyHunterEvent,
                      timeStart: luckyHunterNow,
                      timeFinish: luckyHunterNow,
                      url: uri?.toString() ?? '',
                      appSid:
                      luckyHunterAnalyticsSpyService.luckyHunterAppsFlyerUid,
                      firstPageLoadTs: luckyHunterFirstPageTimestamp,
                    );
                  },
                  onReceivedError: (
                      InAppWebViewController controller,
                      WebResourceRequest request,
                      WebResourceError error,
                      ) async {
                    final int luckyHunterNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String luckyHunterDescription =
                    (error.description ?? '').toString();
                    final String luckyHunterEvent =
                        'WebResourceError(code=$error, message=$luckyHunterDescription)';

                    await luckyHunterPostStat(
                      event: luckyHunterEvent,
                      timeStart: luckyHunterNow,
                      timeFinish: luckyHunterNow,
                      url: request.url?.toString() ?? '',
                      appSid:
                      luckyHunterAnalyticsSpyService.luckyHunterAppsFlyerUid,
                      firstPageLoadTs: luckyHunterFirstPageTimestamp,
                    );
                  },
                  onLoadStop: (
                      InAppWebViewController controller,
                      Uri? uri,
                      ) async {
                    await luckyHunterPushDeviceInfo();
                    await luckyHunterPushAppsFlyerData();

                    setState(() {
                      luckyHunterCurrentUrl = uri.toString();
                    });

                    Future<void>.delayed(
                      const Duration(seconds: 20),
                          () {
                        luckyHunterSendLoadedOnce(
                          url: luckyHunterCurrentUrl.toString(),
                          timestart: luckyHunterStartLoadTimestamp,
                        );
                      },
                    );
                  },
                  shouldOverrideUrlLoading: (
                      InAppWebViewController controller,
                      NavigationAction action,
                      ) async {
                    final Uri? luckyHunterUri = action.request.url;
                    if (luckyHunterUri == null) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    if (luckyHunterIsBareEmail(luckyHunterUri)) {
                      final Uri luckyHunterMailto =
                      luckyHunterToMailto(luckyHunterUri);
                      await luckyHunterOpenMailWeb(luckyHunterMailto);
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String luckyHunterScheme =
                    luckyHunterUri.scheme.toLowerCase();

                    if (luckyHunterScheme == 'mailto') {
                      await luckyHunterOpenMailWeb(luckyHunterUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (luckyHunterScheme == 'tel') {
                      await launchUrl(
                        luckyHunterUri,
                        mode: LaunchMode.externalApplication,
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String luckyHunterHost =
                    luckyHunterUri.host.toLowerCase();
                    final bool luckyHunterIsSocial =
                        luckyHunterHost.endsWith('facebook.com') ||
                            luckyHunterHost.endsWith('instagram.com') ||
                            luckyHunterHost.endsWith('twitter.com') ||
                            luckyHunterHost.endsWith('x.com');

                    if (luckyHunterIsSocial) {
                      await luckyHunterOpenExternal(luckyHunterUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (luckyHunterIsPlatformLink(luckyHunterUri)) {
                      final Uri luckyHunterWebUri =
                      luckyHunterHttpizePlatformUri(luckyHunterUri);
                      await luckyHunterOpenExternal(luckyHunterWebUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (luckyHunterScheme != 'http' &&
                        luckyHunterScheme != 'https') {
                      return NavigationActionPolicy.CANCEL;
                    }

                    return NavigationActionPolicy.ALLOW;
                  },
                  onCreateWindow: (
                      InAppWebViewController controller,
                      CreateWindowAction request,
                      ) async {
                    final Uri? luckyHunterUri = request.request.url;
                    if (luckyHunterUri == null) {
                      return false;
                    }

                    if (luckyHunterIsBareEmail(luckyHunterUri)) {
                      final Uri luckyHunterMailto =
                      luckyHunterToMailto(luckyHunterUri);
                      await luckyHunterOpenMailWeb(luckyHunterMailto);
                      return false;
                    }

                    final String luckyHunterScheme =
                    luckyHunterUri.scheme.toLowerCase();

                    if (luckyHunterScheme == 'mailto') {
                      await luckyHunterOpenMailWeb(luckyHunterUri);
                      return false;
                    }

                    if (luckyHunterScheme == 'tel') {
                      await launchUrl(
                        luckyHunterUri,
                        mode: LaunchMode.externalApplication,
                      );
                      return false;
                    }

                    final String luckyHunterHost =
                    luckyHunterUri.host.toLowerCase();
                    final bool luckyHunterIsSocial =
                        luckyHunterHost.endsWith('facebook.com') ||
                            luckyHunterHost.endsWith('instagram.com') ||
                            luckyHunterHost.endsWith('twitter.com') ||
                            luckyHunterHost.endsWith('x.com');

                    if (luckyHunterIsSocial) {
                      await luckyHunterOpenExternal(luckyHunterUri);
                      return false;
                    }

                    if (luckyHunterIsPlatformLink(luckyHunterUri)) {
                      final Uri luckyHunterWebUri =
                      luckyHunterHttpizePlatformUri(luckyHunterUri);
                      await luckyHunterOpenExternal(luckyHunterWebUri);
                      return false;
                    }

                    if (luckyHunterScheme == 'http' ||
                        luckyHunterScheme == 'https') {
                      controller.loadUrl(
                        urlRequest: URLRequest(
                          url: WebUri(luckyHunterUri.toString()),
                        ),
                      );
                    }

                    return false;
                  },
                  onDownloadStartRequest: (
                      InAppWebViewController controller,
                      DownloadStartRequest req,
                      ) async {
                    await luckyHunterOpenExternal(req.url);
                  },
                ),
                Visibility(
                  visible: !luckyHunterVeilVisible,
                  child: const LuckyHunterNeonLoader(),
                ),
              ],
            ),
          ),
      ],
    );

    if (luckyHunterUseSafeArea) {
      luckyHunterContent = SafeArea(child: luckyHunterContent);
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: luckyHunterContent,
      ),
    );
  }
}

// ============================================================================
// main()
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(luckyHunterFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LuckyHunterHall(),
    ),
  );
}