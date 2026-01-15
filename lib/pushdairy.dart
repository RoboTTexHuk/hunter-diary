import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemUiOverlayStyle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// Если эти классы есть в main.dart – оставь импорт.
import 'main.dart' show MafiaHarbor, CaptainHarbor, BillHarbor;

// ============================================================================
// LuckyHunter инфраструктура и паттерны
// ============================================================================

class LuckyHunterLogger {
  const LuckyHunterLogger();

  void luckyHunterLogInfo(Object message) =>
      debugPrint('[WheelLogger] $message');
  void luckyHunterLogWarn(Object message) =>
      debugPrint('[WheelLogger/WARN] $message');
  void luckyHunterLogError(Object message) =>
      debugPrint('[WheelLogger/ERR] $message');
}

class LuckyHunterVault {
  static final LuckyHunterVault luckyHunterInstance =
  LuckyHunterVault._luckyHunterInternal();
  LuckyHunterVault._luckyHunterInternal();
  factory LuckyHunterVault() => luckyHunterInstance;

  final LuckyHunterLogger luckyHunterLogger = const LuckyHunterLogger();
}

// ============================================================================
// Константы (статистика/кеш)
// ============================================================================

const String luckyHunterLoadedOnceKey = 'wheel_loaded_once';
const String luckyHunterStatEndpoint =
    'https://getgame.portalroullete.bar/stat';
const String luckyHunterCachedFcmKey = 'wheel_cached_fcm';

// ============================================================================
// Утилиты: LuckyHunterKit
// ============================================================================

class LuckyHunterKit {
  static bool luckyHunterLooksLikeBareMail(Uri uri) {
    final String luckyHunterScheme = uri.scheme;
    if (luckyHunterScheme.isNotEmpty) return false;
    final String luckyHunterRaw = uri.toString();
    return luckyHunterRaw.contains('@') && !luckyHunterRaw.contains(' ');
  }

  static Uri luckyHunterToMailto(Uri uri) {
    final String luckyHunterFull = uri.toString();
    final List<String> luckyHunterBits = luckyHunterFull.split('?');
    final String luckyHunterWho = luckyHunterBits.first;
    final Map<String, String> luckyHunterQuery =
    luckyHunterBits.length > 1
        ? Uri.splitQueryString(luckyHunterBits[1])
        : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: luckyHunterWho,
      queryParameters:
      luckyHunterQuery.isEmpty ? null : luckyHunterQuery,
    );
  }

  static Uri luckyHunterGmailize(Uri luckyHunterMailUri) {
    final Map<String, String> luckyHunterQp =
        luckyHunterMailUri.queryParameters;
    final Map<String, String> luckyHunterParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (luckyHunterMailUri.path.isNotEmpty)
        'to': luckyHunterMailUri.path,
      if ((luckyHunterQp['subject'] ?? '').isNotEmpty)
        'su': luckyHunterQp['subject']!,
      if ((luckyHunterQp['body'] ?? '').isNotEmpty)
        'body': luckyHunterQp['body']!,
      if ((luckyHunterQp['cc'] ?? '').isNotEmpty)
        'cc': luckyHunterQp['cc']!,
      if ((luckyHunterQp['bcc'] ?? '').isNotEmpty)
        'bcc': luckyHunterQp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', luckyHunterParams);
  }

  static String luckyHunterDigitsOnly(String luckyHunterSource) =>
      luckyHunterSource.replaceAll(RegExp(r'[^0-9+]'), '');
}

// ============================================================================
// Сервис открытия ссылок: LuckyHunterLinker
// ============================================================================

class LuckyHunterLinker {
  static Future<bool> luckyHunterOpen(Uri luckyHunterUri) async {
    try {
      if (await launchUrl(
        luckyHunterUri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }
      return await launchUrl(
        luckyHunterUri,
        mode: LaunchMode.externalApplication,
      );
    } catch (luckyHunterError) {
      debugPrint('WheelLinker error: $luckyHunterError; url=$luckyHunterUri');
      try {
        return await launchUrl(
          luckyHunterUri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }
}

// ============================================================================
// FCM Background Handler
// ============================================================================

@pragma('vm:entry-point')
Future<void> luckyHunterFcmBackgroundHandler(
    RemoteMessage luckyHunterMessage) async {
  debugPrint("Spin ID: ${luckyHunterMessage.messageId}");
  debugPrint("Spin Data: ${luckyHunterMessage.data}");
}

// ============================================================================
// LuckyHunterDeviceProfile: информация об устройстве
// ============================================================================

class LuckyHunterDeviceProfile {
  String? luckyHunterDeviceId;
  String? luckyHunterSessionId = 'wheel-one-off';
  String? luckyHunterPlatformKind;
  String? luckyHunterOsBuild;
  String? luckyHunterAppVersion;
  String? luckyHunterLocaleCode;
  String? luckyHunterTimezoneName;
  bool luckyHunterPushEnabled = true;

  Future<void> luckyHunterInitialize() async {
    final DeviceInfoPlugin luckyHunterInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo luckyHunterAndroidInfo =
      await luckyHunterInfoPlugin.androidInfo;
      luckyHunterDeviceId = luckyHunterAndroidInfo.id;
      luckyHunterPlatformKind = 'android';
      luckyHunterOsBuild = luckyHunterAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo luckyHunterIosInfo =
      await luckyHunterInfoPlugin.iosInfo;
      luckyHunterDeviceId = luckyHunterIosInfo.identifierForVendor;
      luckyHunterPlatformKind = 'ios';
      luckyHunterOsBuild = luckyHunterIosInfo.systemVersion;
    }

    final PackageInfo luckyHunterPackageInfo =
    await PackageInfo.fromPlatform();
    luckyHunterAppVersion = luckyHunterPackageInfo.version;
    luckyHunterLocaleCode = Platform.localeName.split('_').first;
    luckyHunterTimezoneName = timezone.local.name;
    luckyHunterSessionId =
    'wheel-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> luckyHunterAsMap({String? fcmToken}) => {
    'fcm_token': fcmToken ?? 'missing_token',
    'device_id': luckyHunterDeviceId ?? 'missing_id',
    'app_name': 'joiler',
    'instance_id': luckyHunterSessionId ?? 'missing_session',
    'platform': luckyHunterPlatformKind ?? 'missing_system',
    'os_version': luckyHunterOsBuild ?? 'missing_build',
    'app_version': luckyHunterAppVersion ?? 'missing_app',
    'language': luckyHunterLocaleCode ?? 'en',
    'timezone': luckyHunterTimezoneName ?? 'UTC',
    'push_enabled': luckyHunterPushEnabled,
  };
}

// ============================================================================
// AppsFlyer шпион: LuckyHunterSpy
// ============================================================================

class LuckyHunterSpy {
  AppsFlyerOptions? luckyHunterOptions;
  AppsflyerSdk? luckyHunterSdk;

  String luckyHunterAppsFlyerUid = '';
  String luckyHunterAppsFlyerData = '';

  void luckyHunterStart({VoidCallback? onUpdate}) {
    final AppsFlyerOptions luckyHunterOpts = AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6756072063',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    luckyHunterOptions = luckyHunterOpts;
    luckyHunterSdk = AppsflyerSdk(luckyHunterOpts);

    luckyHunterSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    luckyHunterSdk?.startSDK(
      onSuccess: () => LuckyHunterVault()
          .luckyHunterLogger
          .luckyHunterLogInfo('WheelSpy started'),
      onError: (luckyHunterCode, luckyHunterMsg) => LuckyHunterVault()
          .luckyHunterLogger
          .luckyHunterLogError(
          'WheelSpy error $luckyHunterCode: $luckyHunterMsg'),
    );

    luckyHunterSdk?.onInstallConversionData((luckyHunterValue) {
      luckyHunterAppsFlyerData = luckyHunterValue.toString();
      onUpdate?.call();
    });

    luckyHunterSdk?.getAppsFlyerUID().then((luckyHunterValue) {
      luckyHunterAppsFlyerUid = luckyHunterValue.toString();
      onUpdate?.call();
    });
  }
}

// ============================================================================
// Мост для FCM токена: LuckyHunterFcmBridge
// ============================================================================

class LuckyHunterFcmBridge {
  final LuckyHunterLogger luckyHunterLog = const LuckyHunterLogger();
  String? luckyHunterToken;
  final List<void Function(String)> luckyHunterWaiters =
  <void Function(String)>[];

  String? get luckyHunterFcmToken => luckyHunterToken;

  LuckyHunterFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall luckyHunterCall) async {
      if (luckyHunterCall.method == 'setToken') {
        final String luckyHunterTokenString =
        luckyHunterCall.arguments as String;
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
      final String? luckyHunterCached =
      luckyHunterPrefs.getString(luckyHunterCachedFcmKey);
      if (luckyHunterCached != null && luckyHunterCached.isNotEmpty) {
        luckyHunterSetToken(luckyHunterCached, notify: false);
      }
    } catch (_) {}
  }

  Future<void> luckyHunterPersistToken(String luckyHunterNewToken) async {
    try {
      final SharedPreferences luckyHunterPrefs =
      await SharedPreferences.getInstance();
      await luckyHunterPrefs.setString(
          luckyHunterCachedFcmKey, luckyHunterNewToken);
    } catch (_) {}
  }

  void luckyHunterSetToken(
      String luckyHunterNewToken, {
        bool notify = true,
      }) {
    luckyHunterToken = luckyHunterNewToken;
    luckyHunterPersistToken(luckyHunterNewToken);
    if (notify) {
      for (final void Function(String) luckyHunterCallback
      in List<void Function(String)>.from(luckyHunterWaiters)) {
        try {
          luckyHunterCallback(luckyHunterNewToken);
        } catch (luckyHunterErr) {
          luckyHunterLog
              .luckyHunterLogWarn('fcm waiter error: $luckyHunterErr');
        }
      }
      luckyHunterWaiters.clear();
    }
  }

  Future<void> luckyHunterWaitForToken(
      Function(String luckyHunterTokenValue) luckyHunterOnToken,
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

      luckyHunterWaiters.add(luckyHunterOnToken);
    } catch (luckyHunterErr) {
      luckyHunterLog
          .luckyHunterLogError('wheelWaitToken error: $luckyHunterErr');
    }
  }
}

// ============================================================================
// Неоновый Loader Lucky / Hunter
// ============================================================================

class LuckyHunterNeonLoader extends StatefulWidget {
  const LuckyHunterNeonLoader({Key? key}) : super(key: key);

  @override
  State<LuckyHunterNeonLoader> createState() => _LuckyHunterNeonLoaderState();
}

class _LuckyHunterNeonLoaderState extends State<LuckyHunterNeonLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController luckyHunterAnimationController;
  late Animation<double> luckyHunterPositionAnimation;
  late Animation<double> luckyHunterGlowAnimation;

  @override
  void initState() {
    super.initState();

    luckyHunterAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);

    luckyHunterPositionAnimation = CurvedAnimation(
      parent: luckyHunterAnimationController,
      curve: Curves.easeInOut,
    );

    luckyHunterGlowAnimation = CurvedAnimation(
      parent: luckyHunterAnimationController,
      curve: Curves.easeInOut,
    );
  }

  @override
  void dispose() {
    luckyHunterAnimationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Size luckyHunterSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: AnimatedBuilder(
        animation: luckyHunterAnimationController,
        builder: (BuildContext luckyHunterCtx, Widget? luckyHunterChild) {
          final double luckyHunterT = luckyHunterPositionAnimation.value;
          final double luckyHunterGlow =
              0.4 + 0.6 * luckyHunterGlowAnimation.value;

          final double luckyHunterCenterY = luckyHunterSize.height / 2;

          // Верхнее слово "Hunter" — едет вниз
          final double luckyHunterTopStartY = luckyHunterCenterY - 140;
          final double luckyHunterTopEndY = luckyHunterCenterY - 40;
          final double luckyHunterTopY = luckyHunterTopStartY +
              (luckyHunterTopEndY - luckyHunterTopStartY) * luckyHunterT;

          // Нижнее слово "Lucky" — едет вверх
          final double luckyHunterBottomStartY = luckyHunterCenterY + 140;
          final double luckyHunterBottomEndY = luckyHunterCenterY + 40;
          final double luckyHunterBottomY = luckyHunterBottomStartY +
              (luckyHunterBottomEndY - luckyHunterBottomStartY) *
                  luckyHunterT;

          return CustomPaint(
            size: luckyHunterSize,
            painter: LuckyHunterNeonPainter(
              luckyHunterTopY: luckyHunterTopY,
              luckyHunterBottomY: luckyHunterBottomY,
              luckyHunterGlowStrength: luckyHunterGlow,
            ),
          );
        },
      ),
    );
  }
}

class LuckyHunterNeonPainter extends CustomPainter {
  final double luckyHunterTopY;
  final double luckyHunterBottomY;
  final double luckyHunterGlowStrength;

  LuckyHunterNeonPainter({
    required this.luckyHunterTopY,
    required this.luckyHunterBottomY,
    required this.luckyHunterGlowStrength,
  });

  @override
  void paint(Canvas luckyHunterCanvas, Size luckyHunterSize) {
    luckyHunterCanvas.drawRect(
      Offset.zero & luckyHunterSize,
      Paint()..color = Colors.black,
    );

    final double luckyHunterCenterX = luckyHunterSize.width / 2;

    final Paint luckyHunterBackgroundGlow = Paint()
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.deepPurple.withOpacity(0.05 * luckyHunterGlowStrength),
          Colors.deepPurple.withOpacity(0.35 * luckyHunterGlowStrength),
          Colors.black,
        ],
        stops: const <double>[0.0, 0.4, 1.0],
      ).createShader(
        Rect.fromCircle(
          center: Offset(luckyHunterCenterX, luckyHunterSize.height / 2),
          radius: luckyHunterSize.width * 0.8,
        ),
      );

    luckyHunterCanvas.drawCircle(
      Offset(luckyHunterCenterX, luckyHunterSize.height / 2),
      luckyHunterSize.width * 0.8,
      luckyHunterBackgroundGlow,
    );

    final TextStyle luckyHunterBaseStyle = TextStyle(
      fontSize: 44,
      fontWeight: FontWeight.w900,
      letterSpacing: 6,
      color: Colors.white,
      shadows: <Shadow>[
        Shadow(
          color: Colors.deepPurpleAccent
              .withOpacity(0.9 * luckyHunterGlowStrength),
          blurRadius: 22 * luckyHunterGlowStrength,
          offset: const Offset(0, 0),
        ),
        Shadow(
          color:
          Colors.white.withOpacity(0.7 * luckyHunterGlowStrength),
          blurRadius: 8 * luckyHunterGlowStrength,
          offset: const Offset(0, 0),
        ),
      ],
    );

    final TextPainter luckyHunterTopTextPainter = TextPainter(
      text: TextSpan(
        text: 'Hunter',
        style: luckyHunterBaseStyle.copyWith(
          foreground: Paint()
            ..shader = LinearGradient(
              colors: <Color>[
                Colors.purpleAccent,
                Colors.white,
                Colors.deepPurpleAccent,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ).createShader(const Rect.fromLTWH(0, 0, 200, 50)),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    luckyHunterTopTextPainter.paint(
      luckyHunterCanvas,
      Offset(
        (luckyHunterSize.width - luckyHunterTopTextPainter.width) / 2,
        luckyHunterTopY,
      ),
    );

    final TextPainter luckyHunterBottomTextPainter = TextPainter(
      text: TextSpan(
        text: 'Lucky',
        style: luckyHunterBaseStyle.copyWith(
          fontSize: 50,
          foreground: Paint()
            ..shader = LinearGradient(
              colors: <Color>[
                Colors.white,
                Colors.purpleAccent,
                Colors.white,
              ],
              begin: Alignment.bottomRight,
              end: Alignment.topLeft,
            ).createShader(const Rect.fromLTWH(0, 0, 200, 60)),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    luckyHunterBottomTextPainter.paint(
      luckyHunterCanvas,
      Offset(
        (luckyHunterSize.width - luckyHunterBottomTextPainter.width) / 2,
        luckyHunterBottomY,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant LuckyHunterNeonPainter oldDelegate) =>
      oldDelegate.luckyHunterTopY != luckyHunterTopY ||
          oldDelegate.luckyHunterBottomY != luckyHunterBottomY ||
          oldDelegate.luckyHunterGlowStrength != luckyHunterGlowStrength;
}

// ============================================================================
// Статистика
// ============================================================================

Future<String> luckyHunterFinalUrl(
    String luckyHunterStartUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient luckyHunterClient = HttpClient();

  try {
    Uri luckyHunterCurrentUri = Uri.parse(luckyHunterStartUrl);

    for (int luckyHunterI = 0; luckyHunterI < maxHops; luckyHunterI++) {
      final HttpClientRequest luckyHunterRequest =
      await luckyHunterClient.getUrl(luckyHunterCurrentUri);
      luckyHunterRequest.followRedirects = false;
      final HttpClientResponse luckyHunterResponse =
      await luckyHunterRequest.close();

      if (luckyHunterResponse.isRedirect) {
        final String? luckyHunterLoc =
        luckyHunterResponse.headers.value(HttpHeaders.locationHeader);
        if (luckyHunterLoc == null || luckyHunterLoc.isEmpty) break;

        final Uri luckyHunterNextUri = Uri.parse(luckyHunterLoc);
        luckyHunterCurrentUri = luckyHunterNextUri.hasScheme
            ? luckyHunterNextUri
            : luckyHunterCurrentUri.resolveUri(luckyHunterNextUri);
        continue;
      }

      return luckyHunterCurrentUri.toString();
    }

    return luckyHunterCurrentUri.toString();
  } catch (luckyHunterError) {
    debugPrint('wheelFinalUrl error: $luckyHunterError');
    return luckyHunterStartUrl;
  } finally {
    luckyHunterClient.close(force: true);
  }
}

Future<void> luckyHunterPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageTs,
}) async {
  try {
    final String luckyHunterResolvedUrl =
    await luckyHunterFinalUrl(url);
    final Map<String, dynamic> luckyHunterPayload =
    <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': luckyHunterResolvedUrl,
      'appleID': '6755681349',
      'open_count': '$appSid/$timeStart',
    };

    debugPrint('wheelStat $luckyHunterPayload');

    final http.Response luckyHunterResp = await http.post(
      Uri.parse('$luckyHunterStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(luckyHunterPayload),
    );

    debugPrint(
        'wheelStat resp=${luckyHunterResp.statusCode} body=${luckyHunterResp.body}');
  } catch (luckyHunterError) {
    debugPrint('wheelPostStat error: $luckyHunterError');
  }
}

// ============================================================================
// WebView-экран: LuckyHunterTableView
// ============================================================================

class LuckyHunterTableView extends StatefulWidget
    with WidgetsBindingObserver {
  String luckyHunterStartingUrl;
  LuckyHunterTableView(this.luckyHunterStartingUrl, {super.key});

  @override
  State<LuckyHunterTableView> createState() =>
      _LuckyHunterTableViewState(luckyHunterStartingUrl);
}

class _LuckyHunterTableViewState extends State<LuckyHunterTableView>
    with WidgetsBindingObserver {
  _LuckyHunterTableViewState(this.luckyHunterCurrentUrl);

  final LuckyHunterVault luckyHunterVault = LuckyHunterVault();

  late InAppWebViewController luckyHunterWebViewController;
  String? luckyHunterPushToken;
  final LuckyHunterDeviceProfile luckyHunterDeviceProfile =
  LuckyHunterDeviceProfile();
  final LuckyHunterSpy luckyHunterSpy = LuckyHunterSpy();

  bool luckyHunterOverlayBusy = false;
  String luckyHunterCurrentUrl;
  DateTime? luckyHunterLastPausedAt;

  bool luckyHunterLoadedOnceSent = false;
  int? luckyHunterFirstPageTimestamp;
  int luckyHunterStartLoadTimestamp = 0;

  final Set<String> luckyHunterExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
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

  final Set<String> luckyHunterExternalSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'bnl',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
  };

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(
        luckyHunterFcmBackgroundHandler);

    luckyHunterFirstPageTimestamp =
        DateTime.now().millisecondsSinceEpoch;

    luckyHunterInitPushAndGetToken();
    luckyHunterDeviceProfile.luckyHunterInitialize();
    luckyHunterWireForegroundPushHandlers();
    luckyHunterBindPlatformNotificationTap();
    luckyHunterSpy.luckyHunterStart(onUpdate: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState luckyHunterState) {
    if (luckyHunterState == AppLifecycleState.paused) {
      luckyHunterLastPausedAt = DateTime.now();
    }
    if (luckyHunterState == AppLifecycleState.resumed) {
      if (Platform.isIOS && luckyHunterLastPausedAt != null) {
        final DateTime luckyHunterNow = DateTime.now();
        final Duration luckyHunterDrift =
        luckyHunterNow.difference(luckyHunterLastPausedAt!);
        if (luckyHunterDrift > const Duration(minutes: 25)) {
          luckyHunterForceReloadToLobby();
        }
      }
      luckyHunterLastPausedAt = null;
    }
  }

  void luckyHunterForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      // Здесь можно вернуть в лобби (MafiaHarbor / CaptainHarbor / BillHarbor),
      // если нужно.
    });
  }

  // --------------------------------------------------------------------------
  // Push / FCM
  // --------------------------------------------------------------------------

  void luckyHunterWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage luckyHunterMsg) {
      if (luckyHunterMsg.data['uri'] != null) {
        luckyHunterNavigateTo(luckyHunterMsg.data['uri'].toString());
      } else {
        luckyHunterReturnToCurrentUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage luckyHunterMsg) {
      if (luckyHunterMsg.data['uri'] != null) {
        luckyHunterNavigateTo(luckyHunterMsg.data['uri'].toString());
      } else {
        luckyHunterReturnToCurrentUrl();
      }
    });
  }

  void luckyHunterNavigateTo(String luckyHunterNewUrl) async {
    await luckyHunterWebViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(luckyHunterNewUrl)),
    );
  }

  void luckyHunterReturnToCurrentUrl() async {
    Future<void>.delayed(const Duration(seconds: 3), () {
      luckyHunterWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(luckyHunterCurrentUrl)),
      );
    });
  }

  Future<void> luckyHunterInitPushAndGetToken() async {
    final FirebaseMessaging luckyHunterFm = FirebaseMessaging.instance;
    await luckyHunterFm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    luckyHunterPushToken = await luckyHunterFm.getToken();
  }

  // --------------------------------------------------------------------------
  // Привязка канала: тап по уведомлению из native
  // --------------------------------------------------------------------------

  void luckyHunterBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall luckyHunterCall) async {
      if (luckyHunterCall.method == "onNotificationTap") {
        final Map<String, dynamic> luckyHunterPayload =
        Map<String, dynamic>.from(luckyHunterCall.arguments);
        debugPrint(
            "URI from platform tap: ${luckyHunterPayload['uri']}");
        final String? luckyHunterUriString =
        luckyHunterPayload["uri"]?.toString();
        if (luckyHunterUriString != null &&
            !luckyHunterUriString.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext luckyHunterContext) =>
                  LuckyHunterTableView(luckyHunterUriString),
            ),
                (Route<dynamic> luckyHunterRoute) => false,
          );
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    luckyHunterBindPlatformNotificationTap();

    final bool luckyHunterIsDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: luckyHunterIsDark
          ? SystemUiOverlayStyle.dark
          : SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: <Widget>[
            InAppWebView(
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
              ),
              initialUrlRequest: URLRequest(
                url: WebUri(luckyHunterCurrentUrl),
              ),
              onWebViewCreated:
                  (InAppWebViewController luckyHunterController) {
                luckyHunterWebViewController = luckyHunterController;

                luckyHunterWebViewController.addJavaScriptHandler(
                  handlerName: 'onServerResponse',
                  callback: (List<dynamic> luckyHunterArgs) {
                    luckyHunterVault.luckyHunterLogger.luckyHunterLogInfo(
                        "JS Args: $luckyHunterArgs");
                    try {
                      return luckyHunterArgs.reduce(
                            (dynamic luckyHunterV, dynamic luckyHunterE) =>
                        luckyHunterV + luckyHunterE,
                      );
                    } catch (_) {
                      return luckyHunterArgs.toString();
                    }
                  },
                );
              },
              onLoadStart: (
                  InAppWebViewController luckyHunterController,
                  Uri? luckyHunterUri,
                  ) async {
                luckyHunterStartLoadTimestamp =
                    DateTime.now().millisecondsSinceEpoch;

                if (luckyHunterUri != null) {
                  if (LuckyHunterKit.luckyHunterLooksLikeBareMail(
                      luckyHunterUri)) {
                    try {
                      await luckyHunterController.stopLoading();
                    } catch (_) {}
                    final Uri luckyHunterMailto =
                    LuckyHunterKit.luckyHunterToMailto(
                        luckyHunterUri);
                    await LuckyHunterLinker.luckyHunterOpen(
                      LuckyHunterKit.luckyHunterGmailize(
                          luckyHunterMailto),
                    );
                    return;
                  }

                  final String luckyHunterScheme =
                  luckyHunterUri.scheme.toLowerCase();
                  if (luckyHunterScheme != 'http' &&
                      luckyHunterScheme != 'https') {
                    try {
                      await luckyHunterController.stopLoading();
                    } catch (_) {}
                  }
                }
              },
              onLoadStop: (
                  InAppWebViewController luckyHunterController,
                  Uri? luckyHunterUri,
                  ) async {
                await luckyHunterController.evaluateJavascript(
                  source: "console.log('Hello from Roulette JS!');",
                );

                setState(() {
                  luckyHunterCurrentUrl =
                      luckyHunterUri?.toString() ?? luckyHunterCurrentUrl;
                });

                Future<void>.delayed(const Duration(seconds: 20), () {
                  luckyHunterSendLoadedOnce();
                });
              },
              shouldOverrideUrlLoading: (
                  InAppWebViewController luckyHunterController,
                  NavigationAction luckyHunterNav,
                  ) async {
                final Uri? luckyHunterUri = luckyHunterNav.request.url;
                if (luckyHunterUri == null) {
                  return NavigationActionPolicy.ALLOW;
                }

                if (LuckyHunterKit.luckyHunterLooksLikeBareMail(
                    luckyHunterUri)) {
                  final Uri luckyHunterMailto =
                  LuckyHunterKit.luckyHunterToMailto(luckyHunterUri);
                  await LuckyHunterLinker.luckyHunterOpen(
                    LuckyHunterKit.luckyHunterGmailize(luckyHunterMailto),
                  );
                  return NavigationActionPolicy.CANCEL;
                }

                final String luckyHunterScheme =
                luckyHunterUri.scheme.toLowerCase();

                if (luckyHunterScheme == 'mailto') {
                  await LuckyHunterLinker.luckyHunterOpen(
                    LuckyHunterKit.luckyHunterGmailize(luckyHunterUri),
                  );
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
                  await LuckyHunterLinker.luckyHunterOpen(
                      luckyHunterUri);
                  return NavigationActionPolicy.CANCEL;
                }

                if (luckyHunterIsExternalDestination(luckyHunterUri)) {
                  final Uri luckyHunterMapped =
                  luckyHunterMapExternalToHttp(luckyHunterUri);
                  await LuckyHunterLinker.luckyHunterOpen(
                      luckyHunterMapped);
                  return NavigationActionPolicy.CANCEL;
                }

                if (luckyHunterScheme != 'http' &&
                    luckyHunterScheme != 'https') {
                  return NavigationActionPolicy.CANCEL;
                }

                return NavigationActionPolicy.ALLOW;
              },
              onCreateWindow: (
                  InAppWebViewController luckyHunterController,
                  CreateWindowAction luckyHunterReq,
                  ) async {
                final Uri? luckyHunterUrl = luckyHunterReq.request.url;
                if (luckyHunterUrl == null) return false;

                if (LuckyHunterKit.luckyHunterLooksLikeBareMail(
                    luckyHunterUrl)) {
                  final Uri luckyHunterMail =
                  LuckyHunterKit.luckyHunterToMailto(luckyHunterUrl);
                  await LuckyHunterLinker.luckyHunterOpen(
                    LuckyHunterKit.luckyHunterGmailize(luckyHunterMail),
                  );
                  return false;
                }

                final String luckyHunterScheme =
                luckyHunterUrl.scheme.toLowerCase();

                if (luckyHunterScheme == 'mailto') {
                  await LuckyHunterLinker.luckyHunterOpen(
                    LuckyHunterKit.luckyHunterGmailize(luckyHunterUrl),
                  );
                  return false;
                }

                if (luckyHunterScheme == 'tel') {
                  await launchUrl(
                    luckyHunterUrl,
                    mode: LaunchMode.externalApplication,
                  );
                  return false;
                }

                final String luckyHunterHost =
                luckyHunterUrl.host.toLowerCase();
                final bool luckyHunterIsSocial =
                    luckyHunterHost.endsWith('facebook.com') ||
                        luckyHunterHost.endsWith('instagram.com') ||
                        luckyHunterHost.endsWith('twitter.com') ||
                        luckyHunterHost.endsWith('x.com');

                if (luckyHunterIsSocial) {
                  await LuckyHunterLinker.luckyHunterOpen(luckyHunterUrl);
                  return false;
                }

                if (luckyHunterIsExternalDestination(luckyHunterUrl)) {
                  final Uri luckyHunterMapped =
                  luckyHunterMapExternalToHttp(luckyHunterUrl);
                  await LuckyHunterLinker.luckyHunterOpen(
                      luckyHunterMapped);
                  return false;
                }

                if (luckyHunterScheme == 'http' ||
                    luckyHunterScheme == 'https') {
                  luckyHunterController.loadUrl(
                    urlRequest: URLRequest(
                        url: WebUri(luckyHunterUrl.toString())),
                  );
                }

                return false;
              },
            ),
            if (luckyHunterOverlayBusy)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black87,
                  child: Center(
                    child: LuckyHunterNeonLoader(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ========================================================================
  // Внешние “столы” (протоколы/мессенджеры/соцсети)
  // ========================================================================

  bool luckyHunterIsExternalDestination(Uri luckyHunterUri) {
    final String luckyHunterScheme =
    luckyHunterUri.scheme.toLowerCase();
    if (luckyHunterExternalSchemes.contains(luckyHunterScheme)) {
      return true;
    }

    if (luckyHunterScheme == 'http' || luckyHunterScheme == 'https') {
      final String luckyHunterHost =
      luckyHunterUri.host.toLowerCase();
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

  Uri luckyHunterMapExternalToHttp(Uri luckyHunterUri) {
    final String luckyHunterScheme =
    luckyHunterUri.scheme.toLowerCase();

    if (luckyHunterScheme == 'tg' || luckyHunterScheme == 'telegram') {
      final Map<String, String> luckyHunterQp =
          luckyHunterUri.queryParameters;
      final String? luckyHunterDomain = luckyHunterQp['domain'];
      if (luckyHunterDomain != null && luckyHunterDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$luckyHunterDomain',
          <String, String>{
            if (luckyHunterQp['start'] != null)
              'start': luckyHunterQp['start']!,
          },
        );
      }
      final String luckyHunterPath =
      luckyHunterUri.path.isNotEmpty ? luckyHunterUri.path : '';
      return Uri.https(
        't.me',
        '/$luckyHunterPath',
        luckyHunterUri.queryParameters.isEmpty
            ? null
            : luckyHunterUri.queryParameters,
      );
    }

    if (luckyHunterScheme == 'whatsapp') {
      final Map<String, String> luckyHunterQp =
          luckyHunterUri.queryParameters;
      final String? luckyHunterPhone = luckyHunterQp['phone'];
      final String? luckyHunterText = luckyHunterQp['text'];
      if (luckyHunterPhone != null && luckyHunterPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${LuckyHunterKit.luckyHunterDigitsOnly(luckyHunterPhone)}',
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

    if (luckyHunterScheme == 'bnl') {
      final String luckyHunterNewPath =
      luckyHunterUri.path.isNotEmpty ? luckyHunterUri.path : '';
      return Uri.https(
        'bnl.com',
        '/$luckyHunterNewPath',
        luckyHunterUri.queryParameters.isEmpty
            ? null
            : luckyHunterUri.queryParameters,
      );
    }

    return luckyHunterUri;
  }

  Future<void> luckyHunterSendLoadedOnce() async {
    if (luckyHunterLoadedOnceSent) {
      debugPrint('Wheel Loaded already sent, skip');
      return;
    }

    final int luckyHunterNow =
        DateTime.now().millisecondsSinceEpoch;

    await luckyHunterPostStat(
      event: 'Loaded',
      timeStart: luckyHunterStartLoadTimestamp,
      timeFinish: luckyHunterNow,
      url: luckyHunterCurrentUrl,
      appSid: luckyHunterSpy.luckyHunterAppsFlyerUid,
      firstPageTs: luckyHunterFirstPageTimestamp,
    );

    luckyHunterLoadedOnceSent = true;
  }
}