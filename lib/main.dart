import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dairyhunter/pushdairy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
    MethodChannel,
    SystemChrome,
    SystemUiOverlayStyle,
    MethodCall,
    VoidCallback;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

import 'hat_loader.dart';
import 'luckdairy.dart';

// ============================================================================
// Константы
// ============================================================================

const String dhLoadedOnceKey = 'loaded_once';
const String dhStatEndpoint = 'https://apisrc.diaryh.online/stat';
const String dhCachedFcmKey = 'cached_fcm';
const String dhCachedDeepKey = 'cached_deep_push_uri';

const Set<String> kBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> kBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// Лёгкие сервисы
// ============================================================================

class DhLoggerService {
  static final DhLoggerService sharedInstance =
  DhLoggerService._internalConstructor();

  DhLoggerService._internalConstructor();

  factory DhLoggerService() => sharedInstance;

  final Connectivity dhConnectivity = Connectivity();

  void dhLogInfo(Object message) => print('[I] $message');
  void dhLogWarn(Object message) => print('[W] $message');
  void dhLogError(Object message) => print('[E] $message');
}

class DhNetworkService {
  final DhLoggerService dhLogger = DhLoggerService();

  Future<void> dhPostJson(
      String url,
      Map<String, dynamic> data,
      ) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (error) {
      dhLogger.dhLogError('postJson error: $error');
    }
  }
}

// ============================================================================
// Утилита: одновременное сохранение JSON в localStorage и SharedPreferences
// ============================================================================

Future<void> dhSaveJsonToLocalStorageAndPrefs({
  required InAppWebViewController? controller,
  required String key,
  required Map<String, dynamic> data,
}) async {
  final String jsonString = jsonEncode(data);

  if (controller != null) {
    try {
      await controller.evaluateJavascript(
        source: "localStorage.setItem('$key', JSON.stringify($jsonString));",
      );
    } catch (e, st) {
      DhLoggerService()
          .dhLogError('dhSaveJsonToLocalStorageAndPrefs localStorage error: $e\n$st');
    }
  }

  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonString);
  } catch (e, st) {
    DhLoggerService()
        .dhLogError('dhSaveJsonToLocalStorageAndPrefs prefs error: $e\n$st');
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================

class DhDeviceProfile {
  String? dhDeviceId;
  String? dhSessionId = '';
  String? dhPlatformName;
  String? dhOsVersion;
  String? dhAppVersion;
  String? dhLanguageCode;
  String? dhTimezoneName;
  bool dhPushEnabled = false;

  bool dhSafeAreaEnabled = false;
  String? dhSafeAreaColor;

  // по умолчанию false, пока сервер явно не пришлёт fpscashier=true
  bool dhSafeCashier = false;

  String? dhBaseUserAgent;

  Map<String, dynamic>? dhLastPushData;

  Map<String, dynamic>? dhSaveLs;

  Future<void> dhInitialize() async {
    final DeviceInfoPlugin deviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo androidInfo = await deviceInfoPlugin.androidInfo;
      dhDeviceId = androidInfo.id;
      dhPlatformName = 'android';
      dhOsVersion = androidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo iosInfo = await deviceInfoPlugin.iosInfo;
      dhDeviceId = iosInfo.identifierForVendor;
      dhPlatformName = 'ios';
      dhOsVersion = iosInfo.systemVersion;
    }

    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    dhAppVersion = packageInfo.version;
    dhLanguageCode = Platform.localeName.split('_').first;
    dhTimezoneName = tz_zone.local.name;
    dhSessionId = 'test-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> dhToMap({String? fcmToken}) => <String, dynamic>{
    'fcm_token': fcmToken ?? 'missing_token',
    'device_id': dhDeviceId ?? 'missing_id',
    'app_name': 'diaryh',
    'instance_id': dhSessionId ?? 'missing_session',
    'platform': dhPlatformName ?? 'missing_system',
    'os_version': dhOsVersion ?? 'missing_build',
    'app_version': '1.4.1' ?? 'missing_app',
    'language': dhLanguageCode ?? 'en',
    'timezone': dhTimezoneName ?? 'UTC',
    'push_enabled': dhPushEnabled,
    'safe_area_native': dhSafeAreaEnabled,
    'useragent': dhBaseUserAgent ?? 'unknown_useragent',
    'savels': dhSaveLs ?? <String, dynamic>{},
    'fpscashier': dhSafeCashier,
  };
}

// ============================================================================
// AppsFlyer Spy
// ============================================================================

class DhAnalyticsSpyService {
  appsflyer_core.AppsFlyerOptions? dhAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? dhAppsFlyerSdk;

  String dhAppsFlyerUid = '';
  String dhAppsFlyerData = '';

  Map<String, dynamic>? dhAppsFlyerOneLinkData;

  void dhStartTracking({VoidCallback? onUpdate}) {
    final appsflyer_core.AppsFlyerOptions config =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6757854265',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    dhAppsFlyerOptions = config;
    dhAppsFlyerSdk = appsflyer_core.AppsflyerSdk(config);

    dhAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    dhAppsFlyerSdk?.startSDK(
      onSuccess: () =>
          DhLoggerService().dhLogInfo('RetroCarAnalyticsSpy started'),
      onError: (int code, String msg) =>
          DhLoggerService().dhLogError('RetroCarAnalyticsSpy error $code: $msg'),
    );

    dhAppsFlyerSdk?.onInstallConversionData((dynamic value) {
      dhAppsFlyerData = value.toString();
      onUpdate?.call();
    });

    dhAppsFlyerSdk?.getAppsFlyerUID().then((dynamic value) {
      dhAppsFlyerUid = value.toString();
      onUpdate?.call();
    });
  }

  void dhSetOneLinkData(Map<String, dynamic> data) {
    dhAppsFlyerOneLinkData = data;
    DhLoggerService()
        .dhLogInfo('DhAnalyticsSpyService: OneLink data updated: $data');
  }
}

// ============================================================================
// FCM фон
// ============================================================================

@pragma('vm:entry-point')
Future<void> dhFcmBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  DhLoggerService().dhLogInfo('bg-fcm: ${message.messageId}');
  DhLoggerService().dhLogInfo('bg-data: ${message.data}');

  final dynamic link = message.data['uri'];
  if (link != null) {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        dhCachedDeepKey,
        link.toString(),
      );
    } catch (e) {
      DhLoggerService().dhLogError('bg-fcm save deep failed: $e');
    }
  }
}

// ============================================================================
// FCM Bridge — токен
// ============================================================================

class DhFcmBridge {
  final DhLoggerService dhLogger = DhLoggerService();

  static const MethodChannel _tokenChannel =
  MethodChannel('com.example.fcm/token');

  String? dhToken;
  final List<void Function(String)> dhTokenWaiters =
  <void Function(String)>[];

  String? get dhFcmToken => dhToken;

  Timer? _requestTimer;
  int _requestAttempts = 0;
  final int _maxAttempts = 10;

  DhFcmBridge() {
    _tokenChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setToken') {
        final String tokenString = call.arguments as String;
        dhLogger.dhLogInfo(
            'DhFcmBridge: got token from native channel = $tokenString');
        if (tokenString.isNotEmpty) {
          dhSetToken(tokenString);
        }
      }
    });

    dhRestoreToken();
    _requestNativeToken();
    _startRequestTimer();
  }

  Future<void> _requestNativeToken() async {
    try {
      dhLogger.dhLogInfo('DhFcmBridge: request native getToken()');
      final String? token =
      await _tokenChannel.invokeMethod<String>('getToken');
      if (token != null && token.isNotEmpty) {
        dhLogger.dhLogInfo('DhFcmBridge: native getToken() returns $token');
        dhSetToken(token);
      } else {
        dhLogger.dhLogWarn('DhFcmBridge: native getToken() returned empty');
      }
    } catch (e) {
      dhLogger.dhLogWarn('DhFcmBridge: getToken invoke error: $e');
    }
  }

  void _startRequestTimer() {
    _requestTimer?.cancel();
    _requestAttempts = 0;

    _requestTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      if ((dhToken ?? '').isNotEmpty) {
        dhLogger.dhLogInfo(
            'DhFcmBridge: token already set, stop request timer');
        t.cancel();
        return;
      }

      if (_requestAttempts >= _maxAttempts) {
        dhLogger.dhLogWarn(
            'DhFcmBridge: max getToken attempts reached, stop timer');
        t.cancel();
        return;
      }

      _requestAttempts++;
      dhLogger.dhLogInfo(
          'DhFcmBridge: retry getToken() attempt #$_requestAttempts');
      await _requestNativeToken();
    });
  }

  Future<void> dhRestoreToken() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cachedToken = prefs.getString(dhCachedFcmKey);
      if (cachedToken != null && cachedToken.isNotEmpty) {
        dhLogger.dhLogInfo(
            'DhFcmBridge: restored cached token = $cachedToken');
        dhSetToken(cachedToken, notify: false);
      }
    } catch (e) {
      dhLogger.dhLogError('dhRestoreToken error: $e');
    }
  }

  Future<void> dhPersistToken(String newToken) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(dhCachedFcmKey, newToken);
    } catch (e) {
      dhLogger.dhLogError('dhPersistToken error: $e');
    }
  }

  void dhSetToken(
      String newToken, {
        bool notify = true,
      }) {
    dhToken = newToken;
    dhPersistToken(newToken);

    if (notify) {
      for (final void Function(String) callback
      in List<void Function(String)>.from(dhTokenWaiters)) {
        try {
          callback(newToken);
        } catch (error) {
          dhLogger.dhLogWarn('fcm waiter error: $error');
        }
      }
      dhTokenWaiters.clear();
    }
  }

  Future<void> dhWaitForToken(
      Function(String token) onToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((dhToken ?? '').isNotEmpty) {
        onToken(dhToken!);
        return;
      }

      dhTokenWaiters.add(onToken);
    } catch (error) {
      dhLogger.dhLogError('dhWaitForToken error: $error');
    }
  }

  void dispose() {
    _requestTimer?.cancel();
  }
}

// ============================================================================
// Splash / Hall
// ============================================================================

class DhHall extends StatefulWidget {
  const DhHall({Key? key}) : super(key: key);

  @override
  State<DhHall> createState() => _DhHallState();
}

class _DhHallState extends State<DhHall> {
  final DhFcmBridge dhFcmBridgeInstance = DhFcmBridge();
  bool dhNavigatedOnce = false;
  Timer? dhFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    dhFcmBridgeInstance.dhWaitForToken((String token) {
      dhGoToHarbor(token);
    });

    dhFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => dhGoToHarbor(''),
    );
  }

  void dhGoToHarbor(String signal) {
    if (dhNavigatedOnce) return;
    dhNavigatedOnce = true;
    dhFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext context) => DhHarbor(dhSignal: signal),
      ),
    );
  }

  @override
  void dispose() {
    dhFallbackTimer?.cancel();
    dhFcmBridgeInstance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: HatLoaderScreen(),
        ),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class DhBosunViewModel {
  final DhDeviceProfile dhDeviceProfileInstance;
  final DhAnalyticsSpyService dhAnalyticsSpyInstance;

  DhBosunViewModel({
    required this.dhDeviceProfileInstance,
    required this.dhAnalyticsSpyInstance,
  });

  Map<String, dynamic> dhDeviceMap(String? fcmToken) =>
      dhDeviceProfileInstance.dhToMap(fcmToken: fcmToken);

  Map<String, dynamic> dhAppsFlyerPayload(
      String? token, {
        String? deepLink,
      }) {
    final Map<String, dynamic> onelinkData =
        dhAnalyticsSpyInstance.dhAppsFlyerOneLinkData ?? <String, dynamic>{};

    return <String, dynamic>{
      'content': <String, dynamic>{
        'af_data': dhAnalyticsSpyInstance.dhAppsFlyerData,
        'af_id': dhAnalyticsSpyInstance.dhAppsFlyerUid,
        'fb_app_name': 'diaryh',
        'app_name': 'diaryh',
        'onelink': onelinkData,
        'bundle_identifier': 'com.hunterdiaryluck.dairyhunter',
        'app_version': '1.4.1',
        'apple_id': '6757854265',
        'fcm_token': token ?? 'no_token',
        'device_id': dhDeviceProfileInstance.dhDeviceId ?? 'no_device',
        'instance_id': dhDeviceProfileInstance.dhSessionId ?? 'no_instance',
        'platform': dhDeviceProfileInstance.dhPlatformName ?? 'no_type',
        'os_version': dhDeviceProfileInstance.dhOsVersion ?? 'no_os',
        'language': dhDeviceProfileInstance.dhLanguageCode ?? 'en',
        'timezone': dhDeviceProfileInstance.dhTimezoneName ?? 'UTC',
        'push_enabled': dhDeviceProfileInstance.dhPushEnabled,
        'useruid': dhAnalyticsSpyInstance.dhAppsFlyerUid,
        'safearea': dhDeviceProfileInstance.dhSafeAreaEnabled,
        'safearea_color': dhDeviceProfileInstance.dhSafeAreaColor ?? '',
        'useragent':
        dhDeviceProfileInstance.dhBaseUserAgent ?? 'unknown_useragent',
        'push': dhDeviceProfileInstance.dhLastPushData ?? <String, dynamic>{},
        'deep': deepLink,
        'fpscashier': dhDeviceProfileInstance.dhSafeCashier,
      },
    };
  }
}

class DhCourierService {
  final DhBosunViewModel dhBosun;
  final InAppWebViewController? Function() dhGetWebViewController;

  DhCourierService({
    required this.dhBosun,
    required this.dhGetWebViewController,
  });

  Future<InAppWebViewController?> _waitForController({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final DhLoggerService logger = DhLoggerService();
    final DateTime start = DateTime.now();

    while (DateTime.now().difference(start) < timeout) {
      final InAppWebViewController? c = dhGetWebViewController();
      if (c != null) {
        return c;
      }
      await Future<void>.delayed(interval);
    }

    logger.dhLogWarn('_waitForController: timeout, controller is still null');
    return null;
  }

  Future<void> dhPutDeviceToLocalStorage(String? token) async {
    final InAppWebViewController? controller = await _waitForController();
    if (controller == null) return;

    final Map<String, dynamic> map = dhBosun.dhDeviceMap(token);
    DhLoggerService().dhLogInfo("applocal (${jsonEncode(map)});");

    await dhSaveJsonToLocalStorageAndPrefs(
      controller: controller,
      key: 'app_data',
      data: map,
    );
  }

  Future<void> dhSendRawToPage(
      String? token, {
        String? deepLink,
      }) async {
    final InAppWebViewController? controller = await _waitForController();
    if (controller == null) return;

    final Map<String, dynamic> payload =
    dhBosun.dhAppsFlyerPayload(token, deepLink: deepLink);

    final String jsonString = jsonEncode(payload);

    DhLoggerService().dhLogInfo('SendRawData: $jsonString');

    final String jsSafeJson = jsonEncode(jsonString);
    final String jsCode = 'sendRawData($jsSafeJson);';

    try {
      await controller.evaluateJavascript(source: jsCode);
    } catch (e, st) {
      DhLoggerService()
          .dhLogError('dhSendRawToPage evaluateJavascript error: $e\n$st');
    }
  }
}

// ============================================================================
// Статистика
// ============================================================================

Future<String> dhResolveFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient httpClient = HttpClient();

  try {
    Uri currentUri = Uri.parse(startUrl);

    for (int index = 0; index < maxHops; index++) {
      final HttpClientRequest request = await httpClient.getUrl(currentUri);
      request.followRedirects = false;
      final HttpClientResponse response = await request.close();

      if (response.isRedirect) {
        final String? locationHeader =
        response.headers.value(HttpHeaders.locationHeader);
        if (locationHeader == null || locationHeader.isEmpty) {
          break;
        }

        final Uri nextUri = Uri.parse(locationHeader);
        currentUri =
        nextUri.hasScheme ? nextUri : currentUri.resolveUri(nextUri);
        continue;
      }

      return currentUri.toString();
    }

    return currentUri.toString();
  } catch (error) {
    print('goldenLuxuryResolveFinalUrl error: $error');
    return startUrl;
  } finally {
    httpClient.close(force: true);
  }
}

Future<void> dhPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final String resolvedUrl = await dhResolveFinalUrl(url);

    final Map<String, dynamic> payload = <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': resolvedUrl,
      'appleID': '6757854265',
      'open_count': '$appSid/$timeStart',
    };

    print('goldenLuxuryStat $payload');

    final http.Response response = await http.post(
      Uri.parse('$dhStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );

    print(
        'goldenLuxuryStat resp=${response.statusCode} body=${response.body}');
  } catch (error) {
    print('goldenLuxuryPostStat error: $error');
  }
}

// ============================================================================
// Банковские утилиты
// ============================================================================

bool dhIsBankScheme(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  return kBankSchemes.contains(scheme);
}

bool dhIsBankDomain(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String bank in kBankDomains) {
    final String bankHost = bank.toLowerCase();
    if (host == bankHost || host.endsWith('.$bankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> dhOpenBank(Uri uri) async {
  try {
    if (dhIsBankScheme(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        dhIsBankDomain(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }
  } catch (e) {
    print('dhOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// Главный WebView — Harbor
// ============================================================================

class DhHarbor extends StatefulWidget {
  final String? dhSignal;

  const DhHarbor({super.key, required this.dhSignal});

  @override
  State<DhHarbor> createState() => _DhHarborState();
}

class _DhHarborState extends State<DhHarbor> with WidgetsBindingObserver {
  InAppWebViewController? dhWebViewController;

  InAppWebViewController? dhPopupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;

  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  bool _isOpeningExternalNewTab = false;
  final Set<String> _handledNewTabUrls = <String>{};

  Timer? _parentInstallTimer;
  Timer? _popupInstallTimer;

  final String dhHomeUrl = 'https://apisrc.diaryh.online/';

  int dhWebViewKeyCounter = 0;
  DateTime? dhSleepAt;
  bool dhVeilVisible = false;
  double dhWarmProgress = 0.0;
  late Timer dhWarmTimer;
  final int dhWarmSeconds = 6;
  bool dhCoverVisible = true;

  bool dhLoadedOnceSent = false;
  int? dhFirstPageTimestamp;

  DhCourierService? dhCourier;
  DhBosunViewModel? dhBosunInstance;

  String dhCurrentUrl = '';
  int dhStartLoadTimestamp = 0;

  final DhDeviceProfile dhDeviceProfileInstance = DhDeviceProfile();
  final DhAnalyticsSpyService dhAnalyticsSpyInstance = DhAnalyticsSpyService();

  final Set<String> dhSpecialSchemes = <String>{
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

  final Set<String> dhExternalHosts = <String>{
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

  String? dhDeepLinkFromPush;

  String? _baseUserAgent;
  String _currentUserAgent = "";
  String? _currentUrl;

  String? _serverUserAgent;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = const Color(0xFF000000);

  bool _startupSendRawDone = false;

  String? _pendingLoadedJs;

  bool _loadedJsExecutedOnce = false;

  bool _isInGoogleAuth = false;

  List<String> _buttonWhitelist = <String>[];
  bool _showBackButton = false;

  bool _backButtonHiddenAfterTap = false;

  bool _isCurrentlyOnGoogle = false;

  static const MethodChannel _appsFlyerDeepLinkChannel =
  MethodChannel('appsflyer_deeplink_channel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    dhFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;
    _currentUrl = dhHomeUrl;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          dhCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        dhVeilVisible = true;
      });
    });

    _bindPushChannelFromAppDelegate();
    _bindAppsFlyerDeepLinkChannel();
    dhBootHarbor();
  }

  bool _isAboutBlankUrl(String? value) {
    final String u = (value ?? '').trim().toLowerCase();
    return u.isEmpty || u == 'about:blank' || u.startsWith('about:blank');
  }

  bool _isAboutBlankUri(Uri? uri) => _isAboutBlankUrl(uri?.toString());

  void _bindAppsFlyerDeepLinkChannel() {
    _appsFlyerDeepLinkChannel.setMethodCallHandler(
          (MethodCall call) async {
        if (call.method == 'onDeepLink') {
          try {
            final dynamic args = call.arguments;

            Map<String, dynamic> payload;

            print(" Data Deepl link ${args.toString()}");
            if (args is Map) {
              payload = Map<String, dynamic>.from(args as Map);
            } else if (args is String) {
              payload = jsonDecode(args) as Map<String, dynamic>;
            } else {
              payload = <String, dynamic>{'raw': args.toString()};
            }

            DhLoggerService().dhLogInfo(
              'AppsFlyer onDeepLink from iOS: $payload',
            );

            final dynamic raw = payload['raw'];
            if (raw is Map) {
              final Map<String, dynamic> normalized =
              Map<String, dynamic>.from(raw as Map);

              print("One Link Data $normalized");
              dhAnalyticsSpyInstance.dhSetOneLinkData(normalized);
            } else {
              dhAnalyticsSpyInstance.dhSetOneLinkData(payload);
            }
          } catch (e, st) {
            DhLoggerService()
                .dhLogError('Error in onDeepLink handler: $e\n$st');
          }
        }
      },
    );
  }

  void _bindPushChannelFromAppDelegate() {
    const MethodChannel pushChannel = MethodChannel('com.example.fcm/push');

    pushChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setPushData') {
        try {
          Map<String, dynamic> pushData;
          if (call.arguments is Map) {
            pushData = Map<String, dynamic>.from(call.arguments);
            print("Get Push Data $pushData");
          } else if (call.arguments is String) {
            pushData =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
          } else {
            pushData = <String, dynamic>{'raw': call.arguments.toString()};
          }

          DhLoggerService()
              .dhLogInfo('Got push data from AppDelegate: $pushData');

          dhDeviceProfileInstance.dhLastPushData = pushData;

          final dynamic uriRaw = pushData['uri'] ?? pushData['deep_link'];
          if (uriRaw != null && uriRaw.toString().isNotEmpty) {
            final String u = uriRaw.toString();
            dhDeepLinkFromPush = u;
            await dhSaveCachedDeep(u);
          }
        } catch (e, st) {
          DhLoggerService().dhLogError('setPushData handler error: $e\n$st');
        }
      }
    });
  }

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google.com') ||
        full.contains('accounts.google.') ||
        full.contains('googleusercontent.com') ||
        full.contains('gstatic.com');
  }

  Future<void> _applyGoogleUserAgent() async {
    if (dhWebViewController == null) return;

    const String googleUa = 'random';

    if (_currentUserAgent == googleUa) {
      DhLoggerService()
          .dhLogInfo('[UA] Already set to "random" for Google, skip');
      return;
    }

    DhLoggerService().dhLogInfo('[UA] Applying GOOGLE User-Agent: $googleUa');

    try {
      await dhWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      _currentUserAgent = googleUa;
      _isCurrentlyOnGoogle = true;
      print('[UA] GOOGLE WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      DhLoggerService().dhLogError('Error setting Google User-Agent: $e');
    }
  }

  Future<void> _applyGoogleUserAgentForPopup() async {
    if (dhPopupWebViewController == null) return;

    const String googleUa = 'random';

    DhLoggerService()
        .dhLogInfo('[UA] Applying GOOGLE User-Agent to POPUP: $googleUa');

    try {
      await dhPopupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      print('[UA] GOOGLE POPUP USER AGENT: $googleUa');
    } catch (e) {
      DhLoggerService()
          .dhLogError('Error setting Google User-Agent for popup: $e');
    }
  }

  Future<void> _updateUserAgentFromServerPayload(
      Map<dynamic, dynamic> root) async {
    String? fullua;
    String? uatail;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['fullua'] != null &&
          content['fullua'].toString().trim().isNotEmpty) {
        fullua = content['fullua'].toString().trim();
      }
      if (content['uatail'] != null &&
          content['uatail'].toString().trim().isNotEmpty) {
        uatail = content['uatail'].toString().trim();
      }
    }

    if (fullua == null &&
        root['fullua'] != null &&
        root['fullua'].toString().trim().isNotEmpty) {
      fullua = root['fullua'].toString().trim();
    }
    if (uatail == null &&
        root['uatail'] != null &&
        root['uatail'].toString().trim().isNotEmpty) {
      uatail = root['uatail'].toString().trim();
    }

    if (uatail == null) {
      final dynamic adata = root['adata'];
      if (adata is Map &&
          adata['uatail'] != null &&
          adata['uatail'].toString().trim().isNotEmpty) {
        uatail = adata['uatail'].toString().trim();
      }
    }

    await _applyUserAgent(fullua: fullua, uatail: uatail);
  }

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (dhWebViewController == null) return;

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await dhWebViewController!.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          dhDeviceProfileInstance.dhBaseUserAgent = _baseUserAgent;
          DhLoggerService()
              .dhLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        DhLoggerService().dhLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      DhLoggerService()
          .dhLogWarn('Base User-Agent is still null/empty, skip UA update');
      return;
    }

    DhLoggerService().dhLogInfo(
        'Server UA payload: fullua="$fullua", uatail="$uatail", base="$_baseUserAgent"');

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = "${_baseUserAgent!}";
    }

    _serverUserAgent = newUa;
    DhLoggerService().dhLogInfo('Server UA calculated and stored: $_serverUserAgent');
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (dhWebViewController == null) return;

    if (_isCurrentlyOnGoogle) {
      DhLoggerService()
          .dhLogInfo('[UA] Currently on Google page, keeping "random" UA');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) {
      DhLoggerService()
          .dhLogInfo('Normal UA unchanged, keeping: $_currentUserAgent');
      return;
    }

    DhLoggerService().dhLogInfo('Applying NORMAL WebView User-Agent: $targetUa');

    try {
      await dhWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      print('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      DhLoggerService()
          .dhLogError('Error while setting normal User-Agent "$targetUa": $e');
    }
  }

  Future<void> _switchUserAgentForUrl(Uri? uri) async {
    if (uri == null) return;

    if (_isGoogleUrl(uri)) {
      _isCurrentlyOnGoogle = true;
      await _applyGoogleUserAgent();
    } else {
      if (_isCurrentlyOnGoogle) {
        _isCurrentlyOnGoogle = false;
      }
      await _applyNormalUserAgentIfNeeded();
    }
  }

  Future<void> printJsUserAgent() async {
    if (dhWebViewController == null) return;

    try {
      final ua = await dhWebViewController!.evaluateJavascript(
        source: "navigator.userAgent",
      );

      if (ua is String) {
        print('[JS UA] navigator.userAgent = $ua');
      } else {
        print('[JS UA] navigator.userAgent (non-string) = $ua');
      }
    } catch (e, st) {
      print('Error reading navigator.userAgent: $e\n$st');
    }
  }

  Future<void> debugPrintCurrentUserAgent() async {
    DhLoggerService()
        .dhLogInfo('[STATE UA] _currentUserAgent = $_currentUserAgent');
    await printJsUserAgent();
  }

  Future<void> dhLoadLoadedFlag() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    dhLoadedOnceSent = prefs.getBool(dhLoadedOnceKey) ?? false;
  }

  Future<void> dhSaveLoadedFlag() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(dhLoadedOnceKey, true);
    dhLoadedOnceSent = true;
  }

  Future<void> dhLoadCachedDeep() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cached = prefs.getString(dhCachedDeepKey);
      if ((cached ?? '').isNotEmpty) {
        dhDeepLinkFromPush = cached;
      }
    } catch (_) {}
  }

  Future<void> dhSaveCachedDeep(String uri) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(dhCachedDeepKey, uri);
    } catch (_) {}
  }

  Future<void> dhSendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (dhLoadedOnceSent) return;

    final int now = DateTime.now().millisecondsSinceEpoch;

    await dhPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: now,
      url: url,
      appSid: dhAnalyticsSpyInstance.dhAppsFlyerUid,
      firstPageLoadTs: dhFirstPageTimestamp,
    );

    await dhSaveLoadedFlag();
  }

  void dhBootHarbor() {
    dhStartWarmProgress();
    dhWireFcmHandlers();
    dhAnalyticsSpyInstance.dhStartTracking(
      onUpdate: () => setState(() {}),
    );
    dhBindNotificationTap();
    dhPrepareDeviceProfile();
  }

  void dhWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      final dynamic link = message.data['uri'];
      if (link != null) {
        final String uri = link.toString();
        dhDeepLinkFromPush = uri;
        await dhSaveCachedDeep(uri);
      } else {
        dhResetHomeAfterDelay();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      final dynamic link = message.data['uri'];
      if (link != null) {
        final String uri = link.toString();
        dhDeepLinkFromPush = uri;
        await dhSaveCachedDeep(uri);

        dhNavigateToUri(uri);

        await dhPushDeviceInfo();
        await dhPushAppsFlyerData();
      } else {
        dhResetHomeAfterDelay();
      }
    });
  }

  void dhBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> payload =
        Map<String, dynamic>.from(call.arguments);
        final String? uriRaw = payload['uri']?.toString();

        if (uriRaw != null && uriRaw.isNotEmpty && !uriRaw.contains('Нет URI')) {
          final String uri = uriRaw;
          dhDeepLinkFromPush = uri;
          await dhSaveCachedDeep(uri);

          if (!context.mounted) return;

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) => DhTableView(uri),
            ),
                (Route<dynamic> route) => false,
          );

          await dhPushDeviceInfo();
          await dhPushAppsFlyerData();
        }
      }
    });
  }

  Future<void> dhPrepareDeviceProfile() async {
    try {
      await dhDeviceProfileInstance.dhInitialize();

      final FirebaseMessaging messaging = FirebaseMessaging.instance;
      final NotificationSettings settings =
      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      dhDeviceProfileInstance.dhPushEnabled =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
              settings.authorizationStatus == AuthorizationStatus.provisional;

      await dhLoadLoadedFlag();
      await dhLoadCachedDeep();

      dhBosunInstance = DhBosunViewModel(
        dhDeviceProfileInstance: dhDeviceProfileInstance,
        dhAnalyticsSpyInstance: dhAnalyticsSpyInstance,
      );

      dhCourier = DhCourierService(
        dhBosun: dhBosunInstance!,
        dhGetWebViewController: () => dhWebViewController,
      );
    } catch (error) {
      DhLoggerService().dhLogError('dhPrepareDeviceProfile fail: $error');
    }
  }

  void dhNavigateToUri(String link) async {
    try {
      await dhWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(link)),
      );
    } catch (error) {
      DhLoggerService().dhLogError('navigate error: $error');
    }
  }

  void dhResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        dhWebViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(dhHomeUrl)),
        );
      } catch (_) {}
    });
  }

  String? _resolveTokenForShip() {
    if (widget.dhSignal != null && widget.dhSignal!.isNotEmpty) {
      return widget.dhSignal;
    }
    return null;
  }

  Future<void> _sendAllDataToPageTwice() async {
    await dhPushDeviceInfo();

    Future<void>.delayed(const Duration(seconds: 6), () async {
      await dhPushDeviceInfo();
      await dhPushAppsFlyerData();
    });
  }

  Future<void> dhPushDeviceInfo() async {
    final String? token = _resolveTokenForShip();

    try {
      await dhCourier?.dhPutDeviceToLocalStorage(token);
    } catch (error) {
      DhLoggerService().dhLogError('dhPushDeviceInfo error: $error');
    }
  }

  Future<void> dhPushAppsFlyerData() async {
    final String? token = _resolveTokenForShip();

    try {
      await dhCourier?.dhSendRawToPage(
        token,
        deepLink: dhDeepLinkFromPush,
      );
    } catch (error) {
      DhLoggerService().dhLogError('dhPushAppsFlyerData error: $error');
    }
  }

  void dhStartWarmProgress() {
    int tick = 0;
    dhWarmProgress = 0.0;

    dhWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
          if (!mounted) return;

          setState(() {
            tick++;
            dhWarmProgress = tick / (dhWarmSeconds * 10);

            if (dhWarmProgress >= 1.0) {
              dhWarmProgress = 1.0;
              dhWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      dhSleepAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && dhSleepAt != null) {
        final DateTime now = DateTime.now();
        final Duration drift = now.difference(dhSleepAt!);

        if (drift > const Duration(minutes: 25)) {
          dhReboardHarbor();
        }
      }
      dhSleepAt = null;
    }
  }

  void dhReboardHarbor() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              DhHarbor(dhSignal: widget.dhSignal),
        ),
            (Route<dynamic> route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    dhWarmTimer.cancel();

    _parentInstallTimer?.cancel();
    _popupInstallTimer?.cancel();

    dhWebViewController = null;
    dhPopupWebViewController = null;

    super.dispose();
  }

  bool dhIsBareEmail(Uri uri) {
    final String scheme = uri.scheme;
    if (scheme.isNotEmpty) return false;
    final String raw = uri.toString();
    return raw.contains('@') && !raw.contains(' ');
  }

  Uri dhToMailto(Uri uri) {
    final String full = uri.toString();
    final List<String> parts = full.split('?');
    final String email = parts.first;
    final Map<String, String> queryParams =
    parts.length > 1 ? Uri.splitQueryString(parts[1]) : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: queryParams.isEmpty ? null : queryParams,
    );
  }

  Future<bool> dhOpenMailExternal(Uri mailto) async {
    try {
      final String scheme = mailto.scheme.toLowerCase();
      final String path = mailto.path.toLowerCase();

      DhLoggerService().dhLogInfo(
          'dhOpenMailExternal: scheme=$scheme path=$path uri=$mailto');

      if (scheme != 'mailto') {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        DhLoggerService()
            .dhLogInfo('dhOpenMailExternal: non-mailto result=$ok');
        return ok;
      }

      final bool can = await canLaunchUrl(mailto);
      DhLoggerService()
          .dhLogInfo('dhOpenMailExternal: canLaunchUrl(mailto) = $can');

      if (can) {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        DhLoggerService()
            .dhLogInfo('dhOpenMailExternal: externalApplication result=$ok');
        if (ok) return true;
      }

      DhLoggerService().dhLogWarn(
          'dhOpenMailExternal: no native handler for mailto, fallback to Gmail Web');
      final Uri gmailUri = dhGmailizeMailto(mailto);
      final bool webOk = await dhOpenWeb(gmailUri);
      DhLoggerService()
          .dhLogInfo('dhOpenMailExternal: Gmail Web fallback result=$webOk');
      return webOk;
    } catch (e, st) {
      DhLoggerService()
          .dhLogError('dhOpenMailExternal error: $e\n$st; url=$mailto');
      return false;
    }
  }

  Future<bool> dhOpenMailWeb(Uri mailto) async {
    final Uri gmailUri = dhGmailizeMailto(mailto);
    return dhOpenWeb(gmailUri);
  }

  Uri dhGmailizeMailto(Uri mailUri) {
    final Map<String, String> queryParams = mailUri.queryParameters;

    final Map<String, String> params = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((queryParams['subject'] ?? '').isNotEmpty)
        'su': queryParams['subject']!,
      if ((queryParams['body'] ?? '').isNotEmpty)
        'body': queryParams['body']!,
      if ((queryParams['cc'] ?? '').isNotEmpty) 'cc': queryParams['cc']!,
      if ((queryParams['bcc'] ?? '').isNotEmpty) 'bcc': queryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', params);
  }

  bool dhIsPlatformLink(Uri uri) {
    final String scheme = uri.scheme.toLowerCase();
    if (dhSpecialSchemes.contains(scheme)) {
      return true;
    }

    if (scheme == 'http' || scheme == 'https') {
      final String host = uri.host.toLowerCase();

      if (dhExternalHosts.contains(host)) {
        return true;
      }

      if (host.endsWith('t.me')) return true;
      if (host.endsWith('wa.me')) return true;
      if (host.endsWith('m.me')) return true;
      if (host.endsWith('signal.me')) return true;
      if (host.endsWith('facebook.com')) return true;
      if (host.endsWith('instagram.com')) return true;
      if (host.endsWith('twitter.com')) return true;
      if (host.endsWith('x.com')) return true;
    }

    return false;
  }

  String dhDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri dhHttpizePlatformUri(Uri uri) {
    final String scheme = uri.scheme.toLowerCase();

    if (scheme == 'tg' || scheme == 'telegram') {
      final Map<String, String> qp = uri.queryParameters;
      final String? domain = qp['domain'];

      if (domain != null && domain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$domain',
          <String, String>{
            if (qp['start'] != null) 'start': qp['start']!,
          },
        );
      }

      final String path = uri.path.isNotEmpty ? uri.path : '';

      return Uri.https(
        't.me',
        '/$path',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if ((scheme == 'http' || scheme == 'https') &&
        uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (scheme == 'viber') {
      return uri;
    }

    if (scheme == 'whatsapp') {
      final Map<String, String> qp = uri.queryParameters;
      final String? phone = qp['phone'];
      final String? text = qp['text'];

      if (phone != null && phone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${dhDigitsOnly(phone)}',
          <String, String>{
            if (text != null && text.isNotEmpty) 'text': text,
          },
        );
      }

      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (text != null && text.isNotEmpty) 'text': text,
        },
      );
    }

    if ((scheme == 'http' || scheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') ||
            uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (scheme == 'skype') {
      return uri;
    }

    if (scheme == 'fb-messenger') {
      final String path =
      uri.pathSegments.isNotEmpty ? uri.pathSegments.join('/') : '';
      final Map<String, String> qp = uri.queryParameters;

      final String id = qp['id'] ?? qp['user'] ?? path;

      if (id.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$id',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (scheme == 'sgnl') {
      final Map<String, String> qp = uri.queryParameters;
      final String? phone = qp['phone'];
      final String? username = qp['username'];

      if (phone != null && phone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${dhDigitsOnly(phone)}',
        );
      }

      if (username != null && username.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$username',
        );
      }

      final String path = uri.pathSegments.join('/');
      if (path.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$path',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return uri;
    }

    if (scheme == 'tel') {
      return Uri.parse('tel:${dhDigitsOnly(uri.path)}');
    }

    if (scheme == 'mailto') {
      return uri;
    }

    if (scheme == 'bnl') {
      final String newPath = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        'bnl.com',
        '/$newPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    return uri;
  }

  Future<bool> dhOpenWeb(Uri uri) async {
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

  Future<bool> dhOpenExternal(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      return false;
    }
  }

  void dhHandleServerSavedata(String savedata) {
    print('onServerResponse savedata: $savedata');
   if(savedata=='false') {
     Navigator.pushReplacement(
       context,
       MaterialPageRoute<Widget>(
         builder: (BuildContext context) => LuckyHunterHelpLite(),
       ),
     );
   }
  }

  Color _parseHexColor(String hex) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) {
      value = 'FF$value';
    }
    final intColor = int.tryParse(value, radix: 16) ?? 0xFF000000;
    return Color(intColor);
  }

  Future<void> _updateAppDataInLocalStorageFromProfile() async {
    final InAppWebViewController? controller = dhWebViewController;
    if (controller == null) return;

    final String? token = _resolveTokenForShip();
    final Map<String, dynamic> map =
    dhDeviceProfileInstance.dhToMap(fcmToken: token);

    DhLoggerService()
        .dhLogInfo('updateAppDataFromProfile: ${jsonEncode(map)}');

    await dhSaveJsonToLocalStorageAndPrefs(
      controller: controller,
      key: 'app_data',
      data: map,
    );
  }

  void _updateExtraDataFromServerPayload(Map<dynamic, dynamic> root) {
    try {
      final dynamic adataRaw = root['adata'];
      if (adataRaw is Map) {
        final Map adata = adataRaw;

        final dynamic buttonswlRaw = adata['buttonswl'];
        if (buttonswlRaw is List) {
          final List<String> list = buttonswlRaw
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          setState(() {
            _buttonWhitelist = list;
          });
          DhLoggerService().dhLogInfo('buttonswl updated: $_buttonWhitelist');
          _updateBackButtonVisibility();
        }

        // fpscashier из adata → профиль → localStorage
        if (adata.containsKey('fpscashier')) {
          final dynamic fpsRaw = adata['fpscashier'];
          bool? fpsValue;

          if (fpsRaw is bool) {
            fpsValue = fpsRaw;
          } else if (fpsRaw is num) {
            fpsValue = fpsRaw != 0;
          } else if (fpsRaw is String) {
            final String v = fpsRaw.toLowerCase().trim();
            if (v == 'true' || v == '1' || v == 'yes') fpsValue = true;
            if (v == 'false' || v == '0' || v == 'no') fpsValue = false;
          }

          if (fpsValue != null) {
            final bool old = dhDeviceProfileInstance.dhSafeCashier;
            dhDeviceProfileInstance.dhSafeCashier = fpsValue;
            DhLoggerService().dhLogInfo(
                'fpscashier updated from server payload: $fpsValue');

            _updateAppDataInLocalStorageFromProfile();

            // при переходе из false -> true можно сразу доустановить хуки
            if (!old && fpsValue && dhWebViewController != null) {
              DhLoggerService().dhLogInfo(
                  'fpscashier switched to true, installing JS hooks now');
              _scheduleSafeInstall(dhWebViewController!, label: 'parent');
            }
          }
        }

        final dynamic savelsRaw = adata['savels'];
        if (savelsRaw is Map) {
          dhDeviceProfileInstance.dhSaveLs =
          Map<String, dynamic>.from(savelsRaw);
          DhLoggerService().dhLogInfo(
              'savels stored in profile: ${dhDeviceProfileInstance.dhSaveLs}');
          _updateAppDataInLocalStorageFromProfile();
        }
      }
    } catch (e, st) {
      DhLoggerService()
          .dhLogError('Error in _updateExtraDataFromServerPayload: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    DhLoggerService()
        .dhLogInfo('SAFEAREA RAW PAYLOAD: ${jsonEncode(root)}');

    bool? safearea;
    String? bgLightHex;
    String? bgDarkHex;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['safearea'] != null) {
        final dynamic raw = content['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (content['safearea_color'] != null &&
          content['safearea_color'].toString().trim().isNotEmpty) {
        bgLightHex = content['safearea_color'].toString().trim();
        bgDarkHex = bgLightHex;
      }
    }

    final dynamic adata = root['adata'];
    if (adata is Map) {
      if (safearea == null && adata['safearea'] != null) {
        final dynamic raw = adata['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (adata['bgsareaw'] != null &&
          adata['bgsareaw'].toString().trim().isNotEmpty) {
        bgLightHex = adata['bgsareaw'].toString().trim();
      }
      if (adata['bgsareab'] != null &&
          adata['bgsareab'].toString().trim().isNotEmpty) {
        bgDarkHex = adata['bgsareab'].toString().trim();
      }
    }

    if (safearea == null && root['safearea'] != null) {
      final dynamic raw = root['safearea'];
      if (raw is bool) {
        safearea = raw;
      } else if (raw is String) {
        final String v = raw.toLowerCase().trim();
        if (v == 'true' || v == '1' || v == 'yes') safearea = true;
        if (v == 'false' || v == '0' || v == 'no') safearea = false;
      } else if (raw is num) {
        safearea = raw != 0;
      }
    }

    DhLoggerService().dhLogInfo(
        'SAFEAREA PARSED: enabled=$safearea, light=$bgLightHex, dark=$bgDarkHex');

    if (safearea == null) {
      return;
    }

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    final bool enabled = safearea;
    Color background =
    enabled ? const Color(0xFF1A1A22) : const Color(0xFF000000);

    if (enabled && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex);
    }

    setState(() {
      _safeAreaEnabled = enabled;
      _safeAreaBackgroundColor = background;
      dhDeviceProfileInstance.dhSafeAreaEnabled = enabled;
      dhDeviceProfileInstance.dhSafeAreaColor =
      enabled ? (chosenHex ?? '#1A1A22') : '';
    });

    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool('safearea_enabled', enabled);
        await prefs.setString(
          'safearea_color',
          dhDeviceProfileInstance.dhSafeAreaColor ?? '',
        );
        DhLoggerService().dhLogInfo(
          'SafeArea saved to prefs: enabled=$enabled, color="${dhDeviceProfileInstance.dhSafeAreaColor}"',
        );
      } catch (e, st) {
        DhLoggerService()
            .dhLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();

    DhLoggerService().dhLogInfo(
        'SAFEAREA STATE UPDATED: enabled=$_safeAreaEnabled, color=$_safeAreaBackgroundColor (brightness=$platformBrightness)');
  }

  bool _matchesButtonWhitelist(String url) {
    if (url.isEmpty) return false;
    if (_buttonWhitelist.isEmpty) return false;
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }

    final String host = uri.host.toLowerCase();
    final String full = uri.toString();

    for (final String item in _buttonWhitelist) {
      final String trimmed = item.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        if (full.startsWith(trimmed)) return true;
      } else {
        final String domain = trimmed.toLowerCase();
        if (host == domain || host.endsWith('.$domain')) return true;
      }
    }

    return false;
  }

  Future<void> _updateBackButtonVisibility() async {
    final String current = _currentUrl ?? dhCurrentUrl;
    final bool shouldShow = _matchesButtonWhitelist(current);

    if (_backButtonHiddenAfterTap) {
      _backButtonHiddenAfterTap = false;
    }

    if (shouldShow != _showBackButton) {
      if (mounted) {
        setState(() {
          _showBackButton = shouldShow;
        });
      } else {
        _showBackButton = shouldShow;
      }
    }
  }

  Future<void> _handleBackButtonPressed() async {
    if (mounted) {
      setState(() {
        _backButtonHiddenAfterTap = true;
        _showBackButton = false;
      });
    } else {
      _backButtonHiddenAfterTap = true;
      _showBackButton = false;
    }

    if (_isPopupVisible) {
      await _handlePopupBackPressed();
      return;
    }

    if (dhWebViewController == null) return;
    try {
      if (await dhWebViewController!.canGoBack()) {
        await dhWebViewController!.goBack();
      } else {
        await dhWebViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri(dhHomeUrl)),
        );
      }
    } catch (e, st) {
      DhLoggerService()
          .dhLogError('Error on back button pressed: $e\n$st');
    }
  }

  InAppWebViewSettings _mainWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  InAppWebViewSettings _popupWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  Future<void> _safeEvaluateJavascript(
      InAppWebViewController? controller, {
        required String source,
        String debugName = 'js',
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      print('WERLOG: safeEvaluateJavascript error [$debugName]: $e');
    }
  }

  Future<void> _installJsErrorLogger(InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installJsErrorLogger',
      source: r'''
        (function() {
          if (window.__ncupJsLoggerInstalled) return;
          window.__ncupJsLoggerInstalled = true;

          function serializeError(err) {
            try {
              if (!err) return null;
              var plain = {};
              Object.getOwnPropertyNames(err).forEach(function(key) {
                plain[key] = err[key];
              });
              return plain;
            } catch (_) {
              return { message: String(err) };
            }
          }

          window.onerror = function(message, source, lineno, colno, error) {
            try {
              var payload = {
                type: 'onerror',
                message: String(message || ''),
                source: String(source || ''),
                lineno: lineno || 0,
                colno: colno || 0,
                error: serializeError(error)
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger onerror inner fail', e);
            }
          };

          window.addEventListener('unhandledrejection', function(event) {
            try {
              var reason = event.reason;
              var payload = {
                type: 'unhandledrejection',
                reason: serializeError(reason) || { message: String(reason || '') }
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger unhandledrejection inner fail', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installPostMessageBridge(
      InAppWebViewController controller, {
        required String label,
      }) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installPostMessageBridge-$label',
      source: '''
        (function() {
          if (window.__ncupPostMessageBridgeInstalled_$label) return;
          window.__ncupPostMessageBridgeInstalled_$label = true;

          window.addEventListener('message', function(event) {
            try {
              var dataRaw = event.data;
              var dataString;
              try {
                dataString = JSON.stringify(dataRaw);
              } catch (e) {
                dataString = String(dataRaw);
              }

              var payload = {
                label: '$label',
                origin: String(event.origin || ''),
                data: dataString,
                href: String(window.location.href || '')
              };

              console.log('[NCUP postMessage $label]', payload);

              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupPostMessage', payload);
              }

              try {
                var parsed = dataRaw;
                if (typeof parsed === 'string') {
                  parsed = JSON.parse(parsed);
                }
                if (parsed && parsed.type === 'newTab' && parsed.url) {
                  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('NcupCheckoutAction', parsed);
                  }
                }
              } catch (_) {}
            } catch (e) {
              console.log('NcupPostMessage bridge error', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installCheckoutInterceptor(
      InAppWebViewController controller,
      ) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installCheckoutInterceptor',
      source: r'''
        (function() {
          if (window.__ncupCheckoutInterceptorInstalled) return;
          window.__ncupCheckoutInterceptorInstalled = true;

          function sendToFlutter(data) {
            try {
              if (!data || typeof data !== 'object') return;
              if (data.type === 'newTab' && data.url) {
                console.log('[NCUP checkout interceptor] newTab:', data.url);
                if (
                  window.flutter_inappwebview &&
                  window.flutter_inappwebview.callHandler
                ) {
                  window.flutter_inappwebview.callHandler(
                    'NcupCheckoutAction',
                    data
                  );
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] send error', e);
            }
          }

          function tryParseMaybeJson(value) {
            try {
              if (!value) return null;
              if (typeof value === 'object') {
                return value;
              }
              if (typeof value === 'string') {
                return JSON.parse(value);
              }
              return null;
            } catch (e) {
              return null;
            }
          }

          function tryHandlePayload(payload) {
            try {
              var data = tryParseMaybeJson(payload);
              if (!data) return;

              if (Array.isArray(data)) {
                data.forEach(function(item) {
                  if (item && item.type === 'newTab' && item.url) {
                    sendToFlutter(item);
                  }
                });
                return;
              }

              if (data.type === 'newTab' && data.url) {
                sendToFlutter(data);
                return;
              }

              if (data.savedata) {
                var saved = tryParseMaybeJson(data.savedata);
                if (saved && saved.type === 'newTab' && saved.url) {
                  sendToFlutter(saved);
                  return;
                }
              }

              if (data.data) {
                var nested = tryParseMaybeJson(data.data);
                if (nested && nested.type === 'newTab' && nested.url) {
                  sendToFlutter(nested);
                  return;
                }
              }

              if (data.content) {
                var content = tryParseMaybeJson(data.content);
                if (content && content.type === 'newTab' && content.url) {
                  sendToFlutter(content);
                  return;
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] handle error', e);
            }
          }

          var originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function() {
              return originalFetch.apply(this, arguments).then(function(response) {
                try {
                  var cloned = response.clone();
                  cloned.text().then(function(text) {
                    tryHandlePayload(text);
                  }).catch(function() {});
                } catch (e) {}
                return response;
              });
            };
          }

          var OriginalXHR = window.XMLHttpRequest;
          if (OriginalXHR) {
            window.XMLHttpRequest = function() {
              var xhr = new OriginalXHR();
              var originalOpen = xhr.open;
              var originalSend = xhr.send;

              xhr.open = function() {
                return originalOpen.apply(xhr, arguments);
              };

              xhr.send = function() {
                xhr.addEventListener('load', function() {
                  try {
                    tryHandlePayload(xhr.responseText);
                  } catch (e) {}
                });
                return originalSend.apply(xhr, arguments);
              };

              return xhr;
            };
          }

          var originalOpen = window.open;
          window.open = function(url, target, features) {
            try {
              console.log('[NCUP window.open intercepted]', url, target, features);
            } catch (e) {}

            if (originalOpen) {
              return originalOpen.apply(window, arguments);
            }
            return null;
          };
        })();
      ''',
    );
  }

  Future<void> _installLocalStorageHook(
      InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installLocalStorageHook',
      source: r'''
        (function() {
          if (window.__ncupLocalStorageHookInstalled) return;
          window.__ncupLocalStorageHookInstalled = true;

          try {
            var originalSetItem = window.localStorage.setItem;
            window.localStorage.setItem = function(key, value) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler('NcupLocalStorageSetItem', {
                    key: String(key),
                    value: String(value)
                  });
                }
              } catch (e) {
                console.log('Ncup localStorage hook error', e);
              }
              return originalSetItem.apply(this, arguments);
            };
          } catch (e) {
            console.log('Ncup localStorage hook init error', e);
          }
        })();
      ''',
    );
  }

  Future<void> _safeInstallAll(
      InAppWebViewController? controller, {
        required String label,
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    // хуки ставим только если с сервера пришёл fpscashier=true
    if (!dhDeviceProfileInstance.dhSafeCashier) {
      print('WERLOG: safeInstallAll skipped ($label) because fpscashier=false');
      return;
    }

    try {
      await Future<void>.delayed(
        label == 'popup'
            ? const Duration(milliseconds: 550)
            : const Duration(milliseconds: 250),
      );
      if (!mounted) return;
      await _installJsErrorLogger(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installPostMessageBridge(controller, label: label);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installCheckoutInterceptor(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installLocalStorageHook(controller);
    } catch (e) {
      print('WERLOG: safeInstallAll error label=$label error=$e');
    }
  }

  void _scheduleSafeInstall(
      InAppWebViewController controller, {
        required String label,
      }) {
    if (label == 'popup') {
      _popupInstallTimer?.cancel();
      _popupInstallTimer = Timer(const Duration(milliseconds: 450), () async {
        if (!mounted) return;
        await _safeInstallAll(controller, label: label);
      });
    } else {
      _parentInstallTimer?.cancel();
      _parentInstallTimer = Timer(const Duration(milliseconds: 250), () async {
        if (!mounted) return;
        await _safeInstallAll(controller, label: label);
      });
    }
  }

  Map<String, dynamic>? _tryDecodeMap(dynamic value) {
    try {
      if (value == null) return null;
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is String) {
        final String trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        final dynamic decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _openExternalForJsonNewTab(Uri uri) async {
    if (_isAboutBlankUri(uri)) return false;

    final String url = uri.toString();

    if (_handledNewTabUrls.contains(url)) {
      print('WERLOG: duplicate JSON newTab ignored url=$url');
      return true;
    }

    _handledNewTabUrls.add(url);

    if (_isOpeningExternalNewTab) {
      print('WERLOG: external newTab already opening, ignored url=$url');
      return false;
    }

    _isOpeningExternalNewTab = true;

    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print('WERLOG: JSON newTab external launched=$launched url=$url');
      return launched;
    } catch (e) {
      print('WERLOG: JSON newTab external error=$e url=$url');
      return false;
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        _isOpeningExternalNewTab = false;
      });
    }
  }

  Future<bool> _handleCheckoutAction(dynamic rawPayload) async {
    try {
      Map<String, dynamic>? data = _tryDecodeMap(rawPayload);
      if (data == null) return false;

      if (data.containsKey('savedata')) {
        final Map<String, dynamic>? savedataMap =
        _tryDecodeMap(data['savedata']);
        if (savedataMap != null) {
          data = savedataMap;
        }
      }

      if (data.containsKey('data')) {
        final Map<String, dynamic>? dataMap = _tryDecodeMap(data['data']);
        if (dataMap != null &&
            dataMap['type']?.toString() == 'newTab' &&
            (dataMap['url']?.toString() ?? '').isNotEmpty) {
          data = dataMap;
        }
      }

      if (data.containsKey('content')) {
        final Map<String, dynamic>? contentMap =
        _tryDecodeMap(data['content']);
        if (contentMap != null &&
            contentMap['type']?.toString() == 'newTab' &&
            (contentMap['url']?.toString() ?? '').isNotEmpty) {
          data = contentMap;
        }
      }

      final String type = data['type']?.toString() ?? '';
      final String url = data['url']?.toString() ?? '';

      if (type == 'newTab' && url.isNotEmpty) {
        final Uri? uri = Uri.tryParse(url);
        if (uri == null || _isAboutBlankUri(uri)) {
          print('WERLOG: invalid JSON newTab uri=$url');
          return false;
        }

        print('WERLOG: handle JSON newTab url=$url');
        await _openExternalForJsonNewTab(uri);
        return true;
      }

      return false;
    } catch (e) {
      print('WERLOG: handleCheckoutAction error: $e');
      return false;
    }
  }

  Future<bool> _onCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction request,
      ) async {
    final Uri? uri = request.request.url;
    final String urlString = uri?.toString() ?? '';

    print(
      'WERLOG: MAIN onCreateWindow '
          'windowId=${request.windowId} '
          'url=$urlString '
          'isDialog=${request.isDialog} '
          'hasGesture=${request.hasGesture}',
    );

    if (uri != null) {
      _currentUrl = uri.toString();
      await _updateBackButtonVisibility();

      if (_isGoogleUrl(uri)) {}

      if (dhIsBankScheme(uri) ||
          ((uri.scheme == 'http' || uri.scheme == 'https') &&
              dhIsBankDomain(uri))) {
        await dhOpenBank(uri);
        return false;
      }

      if (dhIsBareEmail(uri)) {
        final Uri mailto = dhToMailto(uri);
        await dhOpenMailExternal(mailto);
        return false;
      }

      final String scheme = uri.scheme.toLowerCase();

      if (scheme == 'mailto') {
        await dhOpenMailExternal(uri);
        return false;
      }

      if (scheme == 'tel') {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        return false;
      }

      final String host = uri.host.toLowerCase();
      final bool isSocial = host.endsWith('facebook.com') ||
          host.endsWith('instagram.com') ||
          host.endsWith('twitter.com') ||
          host.endsWith('x.com');

      if (isSocial) {
        await dhOpenExternal(uri);
        return false;
      }

      if (dhIsPlatformLink(uri)) {
        final Uri webUri = dhHttpizePlatformUri(uri);
        await dhOpenExternal(webUri);
        return false;
      }
    }

    if (!mounted) return false;

    setState(() {
      _popupCreateAction = request;
      _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
          ? urlString
          : null;
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });

    return true;
  }

  Future<bool> _onPopupCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction createWindowAction,
      ) async {
    final Uri? uri = createWindowAction.request.url;
    final String urlString = uri?.toString() ?? '';

    print(
      'WERLOG: POPUP onCreateWindow '
          'windowId=${createWindowAction.windowId} '
          'url=$urlString',
    );

    if (!mounted) return false;

    if (createWindowAction.windowId != null) {
      setState(() {
        _popupCreateAction = createWindowAction;
        _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
            ? urlString
            : _popupUrl;
        _popupCurrentUrl = _popupUrl;
        _isPopupVisible = true;
      });
      return true;
    }

    if (urlString.isNotEmpty && !_isAboutBlankUrl(urlString)) {
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(urlString)),
        );
      } catch (e) {
        print('WERLOG: popup inner window.open load error: $e url=$urlString');
      }
    }

    return false;
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      dhPopupWebViewController = null;
    });
  }

  Future<void> _closePopupAndNotifyParent({
    String reason = 'closed_by_user',
  }) async {
    try {
      await dhWebViewController?.evaluateJavascript(
        source: '''
          try {
            window.dispatchEvent(new MessageEvent('message', {
              data: ${jsonEncode({
          'type': 'ncup_popup_closed',
          'reason': reason,
        })},
              origin: window.location.origin
            }));
          } catch(e) {
            console.log('ncup popup close notify failed', e);
          }
        ''',
      );
    } catch (e) {
      print('WERLOG: closePopup notify parent error: $e');
    }
    _closePopup();
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = dhPopupWebViewController;
    if (c == null) {
      if (_popupCanGoBack && mounted) {
        setState(() {
          _popupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool can = await c.canGoBack();
      if (!mounted) return;
      if (can != _popupCanGoBack) {
        setState(() {
          _popupCanGoBack = can;
        });
      }
    } catch (e) {
      print('WERLOG: _refreshPopupCanGoBack error: $e');
    }
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = dhPopupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          _refreshPopupCanGoBack();
        });
      } else {
        await _closePopupAndNotifyParent(reason: 'popup_back_no_history');
      }
    } catch (e) {
      print('WERLOG: _handlePopupBackPressed error: $e');
      _closePopup();
    }
  }

  bool _isCurrentPopupInWhitelist() {
    if (!_isPopupVisible) return false;
    final String popupUrlForCheck = _popupCurrentUrl ?? _popupUrl ?? '';
    return _matchesButtonWhitelist(popupUrlForCheck);
  }

  Widget _buildPopupWebView() {
    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool showBackArrow = !popupInWhitelist && _popupCanGoBack;
    final bool showCloseButton = !popupInWhitelist && !_popupCanGoBack;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            if (!popupInWhitelist) ...[
              SafeArea(
                bottom: false,
                child: Container(
                  color: Colors.black,
                  child: Row(
                    children: [
                      if (showBackArrow)
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          onPressed: _handlePopupBackPressed,
                        )
                      else if (showCloseButton)
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () {
                            _closePopupAndNotifyParent(reason: 'close_button');
                          },
                        ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
            ],
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null) && _popupUrl != null
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupWebViewSettings(),
                onWebViewCreated:
                    (InAppWebViewController popupController) async {
                  dhPopupWebViewController = popupController;

                  print(
                    'WERLOG: popup created '
                        'windowId=${_popupCreateAction?.windowId} '
                        'initialUrl=${_popupUrl ?? _popupCreateAction?.request.url}',
                  );

                  final String popupInitUrl =
                      _popupUrl ?? _popupCreateAction?.request.url?.toString() ?? '';
                  if (popupInitUrl.isNotEmpty) {
                    final Uri? popupUri = Uri.tryParse(popupInitUrl);
                    if (popupUri != null && _isGoogleUrl(popupUri)) {
                      await _applyGoogleUserAgentForPopup();
                    }
                  }

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupLocalStorageSetItem',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic raw = args.first;
                        if (raw is Map) {
                          final String key = raw['key']?.toString() ?? '';
                          final String value = raw['value']?.toString() ?? '';
                          if (key.isNotEmpty) {
                            final SharedPreferences prefs =
                            await SharedPreferences.getInstance();
                            await prefs.setString(key, value);
                            DhLoggerService().dhLogInfo(
                                'NcupLocalStorageSetItem (popup): saved key="$key" len=${value.length}');
                          }
                        }
                      } catch (e, st) {
                        DhLoggerService().dhLogError(
                            'NcupLocalStorageSetItem popup handler error: $e\n$st');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupCheckoutAction',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupCheckoutAction args=$args');
                      if (args.isNotEmpty) {
                        await _handleCheckoutAction(args.first);
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupPostMessage',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupPostMessage args=$args');
                      if (args.isNotEmpty) {
                        final dynamic first = args.first;
                        if (first is Map && first['data'] != null) {
                          await _handleCheckoutAction(first['data']);
                        } else {
                          await _handleCheckoutAction(first);
                        }
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupJSLogger',
                    callback: (List<dynamic> args) {
                      print('WERLOG: POPUP JS error payload: $args');
                      return null;
                    },
                  );
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStart: (controller, uri) async {
                  print('WERLOG: popup onLoadStart url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (_isGoogleUrl(uri)) {
                      await _applyGoogleUserAgentForPopup();
                    }

                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onLoadStop: (controller, uri) async {
                  print('WERLOG: popup onLoadStop url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                      });
                    }
                  }
                  if (!_isAboutBlankUri(uri)) {
                    _scheduleSafeInstall(controller, label: 'popup');
                  }
                  _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  if (url != null && !_isAboutBlankUri(url)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = url.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onCreateWindow: _onPopupCreateWindowHandler,
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction navigationAction,
                    ) async {
                  final Uri? uri = navigationAction.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isAboutBlankUri(uri)) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isGoogleUrl(uri)) {
                    await _applyGoogleUserAgentForPopup();
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (dhIsBareEmail(uri)) {
                    final Uri mailto = dhToMailto(uri);
                    await dhOpenMailExternal(mailto);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await dhOpenMailExternal(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (dhIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          dhIsBankDomain(uri))) {
                    await dhOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    print(
                      'WERLOG: popup blocked non-http/https scheme=$scheme url=$uri',
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  print('WERLOG: popup onCloseWindow');
                  _closePopup();
                },
                onLoadError: (controller, uri, code, message) async {
                  print(
                    'WERLOG: popup onLoadError url=$uri code=$code msg=$message',
                  );
                },
                onReceivedError: (controller, request, error) async {
                  print(
                    'WERLOG: popup onReceivedError '
                        'url=${request.url} '
                        'type=${error.type} '
                        'desc=${error.description}',
                  );
                },
                onReceivedHttpError:
                    (controller, request, errorResponse) async {
                  print(
                    'WERLOG: popup onReceivedHttpError '
                        'url=${request.url} '
                        'status=${errorResponse.statusCode} '
                        'reason=${errorResponse.reasonPhrase}',
                  );
                },
                onConsoleMessage: (controller, consoleMessage) {
                  print(
                    'WERLOG: popup console: '
                        '${consoleMessage.messageLevel} ${consoleMessage.message}',
                  );
                },
                onDownloadStartRequest: (controller, req) async {
                  print(
                      'WERLOG: popup download for url=${req.url}, opening external');
                  await dhOpenExternal(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    dhBindNotificationTap();

    final Color bgColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget webView = Stack(
      children: <Widget>[
        if (dhCoverVisible)
          const Center(child: HatLoaderScreen())
        else
          Container(
            color: bgColor,
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  key: ValueKey<int>(dhWebViewKeyCounter),
                  initialSettings: _mainWebViewSettings(),
                  initialUrlRequest: URLRequest(
                    url: WebUri(dhHomeUrl),
                  ),
                  onWebViewCreated:
                      (InAppWebViewController controller) async {
                    dhWebViewController = controller;
                    _currentUrl = dhHomeUrl;

                    dhBosunInstance ??= DhBosunViewModel(
                      dhDeviceProfileInstance: dhDeviceProfileInstance,
                      dhAnalyticsSpyInstance: dhAnalyticsSpyInstance,
                    );

                    dhCourier ??= DhCourierService(
                      dhBosun: dhBosunInstance!,
                      dhGetWebViewController: () => dhWebViewController,
                    );

                    try {
                      final ua = await controller.evaluateJavascript(
                        source: "navigator.userAgent",
                      );
                      if (ua is String && ua.trim().isNotEmpty) {
                        _baseUserAgent = ua.trim();
                        _currentUserAgent = _baseUserAgent!;
                        dhDeviceProfileInstance.dhBaseUserAgent =
                            _baseUserAgent;
                        DhLoggerService().dhLogInfo(
                            'Initial WebView User-Agent: $_baseUserAgent');
                        print(
                            '[UA] INITIAL WEBVIEW USER AGENT: $_baseUserAgent');
                      }
                    } catch (e) {
                      DhLoggerService().dhLogWarn(
                          'Failed to read navigator.userAgent on create: $e');
                    }

                    await _applyNormalUserAgentIfNeeded();

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupLocalStorageSetItem',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic raw = args.first;
                          if (raw is Map) {
                            final String key = raw['key']?.toString() ?? '';
                            final String value =
                                raw['value']?.toString() ?? '';
                            if (key.isNotEmpty) {
                              final SharedPreferences prefs =
                              await SharedPreferences.getInstance();
                              await prefs.setString(key, value);
                              DhLoggerService().dhLogInfo(
                                  'NcupLocalStorageSetItem (main): saved key="$key" len=${value.length}');
                            }
                          }
                        } catch (e, st) {
                          DhLoggerService().dhLogError(
                              'NcupLocalStorageSetItem main handler error: $e\n$st');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'onServerResponse',
                      callback: (List<dynamic> args) async {
                        if (args.isEmpty) return null;

                        print("Get Data server $args");

                        try {
                          dynamic first = args[0];

                          if (first is List && first.isNotEmpty) {
                            first = first.first;
                          }

                          final bool handled =
                          await _handleCheckoutAction(first);
                          if (handled) {}

                          if (first is Map) {
                            final Map<dynamic, dynamic> root = first;

                            if (root['savedata'] != null) {
                              dhHandleServerSavedata(
                                  root['savedata'].toString());
                              await _handleCheckoutAction(root['savedata']);
                            }

                            _updateExtraDataFromServerPayload(root);
                            _updateSafeAreaFromServerPayload(root);
                            await _updateUserAgentFromServerPayload(root);

                            await _applyNormalUserAgentIfNeeded();

                            try {
                              if (!_loadedJsExecutedOnce) {
                                final dynamic adataRaw = root['adata'];
                                if (adataRaw is Map) {
                                  final Map adata = adataRaw;
                                  final dynamic loadedJsRaw =
                                  adata['loadedjs'];
                                  if (loadedJsRaw != null) {
                                    final String loadedJs =
                                    loadedJsRaw.toString().trim();
                                    if (loadedJs.isNotEmpty) {
                                      _pendingLoadedJs = loadedJs;
                                      DhLoggerService().dhLogInfo(
                                        'loadedjs received, will execute ONCE after 6 seconds',
                                      );

                                      Future<void>.delayed(
                                        const Duration(seconds: 6),
                                            () async {
                                          if (!mounted) return;
                                          if (_loadedJsExecutedOnce) {
                                            DhLoggerService().dhLogInfo(
                                                'Skipping loadedjs: already executed once');
                                            return;
                                          }
                                          if (dhWebViewController == null) {
                                            DhLoggerService().dhLogWarn(
                                                'Skipping loadedjs execution: controller is null');
                                            return;
                                          }
                                          final String? jsToRun =
                                              _pendingLoadedJs;
                                          if (jsToRun == null ||
                                              jsToRun.isEmpty) {
                                            return;
                                          }
                                          DhLoggerService().dhLogInfo(
                                              'Executing loadedjs from server payload (ONCE, delayed 6s)');
                                          try {
                                            await dhWebViewController
                                                ?.evaluateJavascript(
                                              source: jsToRun,
                                            );
                                            _loadedJsExecutedOnce = true;
                                          } catch (e, st) {
                                            DhLoggerService().dhLogError(
                                                'Error executing delayed loadedjs: $e\n$st');
                                          }
                                        },
                                      );
                                    }
                                  }
                                }
                              } else {
                                DhLoggerService().dhLogInfo(
                                    'loadedjs ignored: already executed once earlier');
                              }
                            } catch (e, st) {
                              DhLoggerService().dhLogError(
                                  'Error scheduling loadedjs: $e\n$st');
                            }
                          }
                        } catch (e, st) {
                          print('onServerResponse error: $e\n$st');
                        }

                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupCheckoutAction',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupCheckoutAction args=$args');
                          if (args.isNotEmpty) {
                            await _handleCheckoutAction(args.first);
                          }
                        } catch (e) {
                          print(
                              'WERLOG: MAIN NcupCheckoutAction error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupJSLogger',
                      callback: (List<dynamic> args) {
                        try {
                          final dynamic payload =
                          args.isNotEmpty ? args.first : null;
                          print('WERLOG: MAIN JS error payload: $payload');
                        } catch (e) {
                          print('WERLOG: NcupJSLogger handler error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupPostMessage',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupPostMessage args=$args');
                          if (args.isNotEmpty) {
                            final dynamic first = args.first;
                            if (first is Map && first['data'] != null) {
                              await _handleCheckoutAction(first['data']);
                            } else {
                              await _handleCheckoutAction(first);
                            }
                          }
                        } catch (e) {
                          print(
                              'WERLOG: NcupPostMessage handler error: $e');
                        }
                        return null;
                      },
                    );
                  },
                  onPermissionRequest: (controller, request) async {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.GRANT,
                    );
                  },
                  onLoadStart:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      dhStartLoadTimestamp =
                          DateTime.now().millisecondsSinceEpoch;
                    });

                    final Uri? viewUri = uri;
                    if (viewUri != null) {
                      _currentUrl = viewUri.toString();

                      await _switchUserAgentForUrl(viewUri);

                      await _updateBackButtonVisibility();

                      if (dhIsBareEmail(viewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        final Uri mailto = dhToMailto(viewUri);
                        await dhOpenMailExternal(mailto);
                        return;
                      }

                      final String scheme =
                      viewUri.scheme.toLowerCase();

                      if (scheme == 'mailto') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await dhOpenMailExternal(viewUri);
                        return;
                      }

                      if (dhIsBankScheme(viewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await dhOpenBank(viewUri);
                        return;
                      }

                      if (scheme != 'http' && scheme != 'https') {
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
                    final int now =
                        DateTime.now().millisecondsSinceEpoch;
                    final String event =
                        'InAppWebViewError(code=$code, message=$message)';

                    await dhPostStat(
                      event: event,
                      timeStart: now,
                      timeFinish: now,
                      url: uri?.toString() ?? '',
                      appSid: dhAnalyticsSpyInstance.dhAppsFlyerUid,
                      firstPageLoadTs: dhFirstPageTimestamp,
                    );
                  },
                  onReceivedError: (
                      InAppWebViewController controller,
                      WebResourceRequest request,
                      WebResourceError error,
                      ) async {
                    final int now =
                        DateTime.now().millisecondsSinceEpoch;
                    final String description =
                    (error.description ?? '').toString();
                    final String event =
                        'WebResourceError(code=$error, message=$description)';

                    await dhPostStat(
                      event: event,
                      timeStart: now,
                      timeFinish: now,
                      url: request.url?.toString() ?? '',
                      appSid: dhAnalyticsSpyInstance.dhAppsFlyerUid,
                      firstPageLoadTs: dhFirstPageTimestamp,
                    );
                  },
                  onLoadStop:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      dhCurrentUrl = uri.toString();
                      _currentUrl = dhCurrentUrl;
                    });

                    if (uri != null) {
                      await _switchUserAgentForUrl(uri);
                    }

                    if (!_isAboutBlankUri(uri)) {
                      _scheduleSafeInstall(controller, label: 'parent');
                    }

                    await debugPrintCurrentUserAgent();

                    await _sendAllDataToPageTwice();
                    await _updateBackButtonVisibility();

                    Future<void>.delayed(
                      const Duration(seconds: 20),
                          () {
                        dhSendLoadedOnce(
                          url: dhCurrentUrl.toString(),
                          timestart: dhStartLoadTimestamp,
                        );
                      },
                    );
                  },
                  onUpdateVisitedHistory:
                      (controller, url, isReload) async {
                    if (url != null && !_isAboutBlankUri(url)) {
                      _currentUrl = url.toString();
                      await _updateBackButtonVisibility();
                      await _switchUserAgentForUrl(url);
                    }
                  },
                  shouldOverrideUrlLoading:
                      (InAppWebViewController controller,
                      NavigationAction action) async {
                    final Uri? uri = action.request.url;
                    if (uri == null) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    _currentUrl = uri.toString();
                    await _updateBackButtonVisibility();

                    if (_isAboutBlankUri(uri)) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    if (_isGoogleUrl(uri)) {
                      _isCurrentlyOnGoogle = true;
                      await _applyGoogleUserAgent();
                      return NavigationActionPolicy.ALLOW;
                    } else {
                      if (_isCurrentlyOnGoogle) {
                        _isCurrentlyOnGoogle = false;
                      }
                      await _applyNormalUserAgentIfNeeded();
                    }

                    if (dhIsBareEmail(uri)) {
                      final Uri mailto = dhToMailto(uri);
                      await dhOpenMailExternal(mailto);
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String scheme = uri.scheme.toLowerCase();

                    if (scheme == 'mailto') {
                      await dhOpenMailExternal(uri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (dhIsBankScheme(uri)) {
                      await dhOpenBank(uri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if ((scheme == 'http' || scheme == 'https') &&
                        dhIsBankDomain(uri)) {
                      await dhOpenBank(uri);

                      if (_isAdobeRedirect(uri)) {
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AdobeRedirectScreen(uri: uri),
                            ),
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (scheme == 'tel') {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String host = uri.host.toLowerCase();
                    final bool isSocial =
                        host.endsWith('facebook.com') ||
                            host.endsWith('instagram.com') ||
                            host.endsWith('twitter.com') ||
                            host.endsWith('x.com');

                    if (isSocial) {
                      await dhOpenExternal(uri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (dhIsPlatformLink(uri)) {
                      final Uri webUri =
                      dhHttpizePlatformUri(uri);
                      await dhOpenExternal(webUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (scheme != 'http' && scheme != 'https') {
                      return NavigationActionPolicy.CANCEL;
                    }

                    return NavigationActionPolicy.ALLOW;
                  },
                  onCreateWindow: _onCreateWindowHandler,
                  onCloseWindow: (controller) {
                    print('WERLOG: MAIN onCloseWindow');
                  },
                  onDownloadStartRequest: (
                      InAppWebViewController controller,
                      DownloadStartRequest req,
                      ) async {
                    await dhOpenExternal(req.url);
                  },
                  onConsoleMessage: (controller, consoleMessage) {
                    print(
                      'WERLOG: MAIN console: '
                          '${consoleMessage.messageLevel} ${consoleMessage.message}',
                    );
                  },
                ),
                Visibility(
                  visible: !dhVeilVisible,
                  child: const Center(child: HatLoaderScreen()),
                ),
                if (_isPopupVisible &&
                    (_popupUrl != null || _popupCreateAction != null))
                  _buildPopupWebView(),
              ],
            ),
          ),
      ],
    );

    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool whitelistMatch =
        (!_isPopupVisible && _showBackButton) || popupInWhitelist;

    final bool shouldShowTopBackBar =
        whitelistMatch && !_backButtonHiddenAfterTap;

    final Color topBarColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget topBackBar = shouldShowTopBackBar
        ? Container(
      color: topBarColor,
      padding: const EdgeInsets.only(left: 4, right: 4),
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBackButtonPressed,
          ),
        ],
      ),
    )
        : const SizedBox.shrink();

    final Widget fullScreen = Column(
      children: [
        topBackBar,
        Expanded(child: webView),
      ],
    );

    final Widget body = _safeAreaEnabled
        ? SafeArea(
      child: fullScreen,
    )
        : fullScreen;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: bgColor,
        body: SizedBox.expand(
          child: ColoredBox(
            color: bgColor,
            child: body,
          ),
        ),
      ),
    );
  }

  bool _isAdobeRedirect(Uri uri) {
    final String host = uri.host.toLowerCase();
    return host == 'c00.adobe.com';
  }
}

// ---------------------- Экран для c00.adobe.com ----------------------

class AdobeRedirectScreen extends StatelessWidget {
  final Uri uri;

  const AdobeRedirectScreen({super.key, required this.uri});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF111111),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Go to the App Store and download the app.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(height: 40),
            ],
          ),
        ),
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
  FirebaseMessaging.onBackgroundMessage(dhFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DhHall(),
    ),
  );
}