import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as DhMath;
import 'dart:ui';

import 'package:appsflyer_sdk/appsflyer_sdk.dart'
    show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, SystemUiOverlayStyle, SystemChrome;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as DhTimezoneData;
import 'package:timezone/timezone.dart' as DhTimezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// Если эти классы есть в main.dart – оставь импорт.
import 'main.dart' show MafiaHarbor, CaptainHarbor, BillHarbor;

// ============================================================================
// Dh инфраструктура (бывшая Dress Retro инфраструктура)
// ============================================================================

class DhLogger {
  const DhLogger();

  void dhLogInfo(Object message) =>
      debugPrint('[DressRetroLogger] $message');

  void dhLogWarn(Object message) =>
      debugPrint('[DressRetroLogger/WARN] $message');

  void dhLogError(Object message) =>
      debugPrint('[DressRetroLogger/ERR] $message');
}

class DhVault {
  static final DhVault sharedInstance = DhVault._internalConstructor();
  DhVault._internalConstructor();
  factory DhVault() => sharedInstance;

  final DhLogger dhLoggerInstance = const DhLogger();
}

// ============================================================================
// Константы (статистика/кеш) — строки в кавычках не меняем
// ============================================================================

const String dhLoadedOnceKey = 'wheel_loaded_once';
const String dhStatEndpoint = 'https://getgame.portalroullete.bar/stat';
const String dhCachedFcmKey = 'wheel_cached_fcm';

// НОВОЕ: ключи для сохранения SafeArea и цвета в SharedPreferences
const String dhSafeAreaEnabledKey = 'safearea_enabled';
const String dhSafeAreaColorKey = 'safearea_color';

// ---------------- Bank constants (из первого main.dart) ----------------

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
// Утилиты: DhKit (бывший DressRetroKit)
// ============================================================================

class DhKit {
  static bool dhLooksLikeBareMail(Uri uri) {
    final String scheme = uri.scheme;
    if (scheme.isNotEmpty) return false;
    final String raw = uri.toString();
    return raw.contains('@') && !raw.contains(' ');
  }

  static Uri dhToMailto(Uri uri) {
    final String full = uri.toString();
    final List<String> bits = full.split('?');
    final String who = bits.first;
    final Map<String, String> query =
    bits.length > 1 ? Uri.splitQueryString(bits[1]) : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: who,
      queryParameters: query.isEmpty ? null : query,
    );
  }

  static Uri dhGmailize(Uri mailUri) {
    final Map<String, String> qp = mailUri.queryParameters;
    final Map<String, String> params = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((qp['subject'] ?? '').isNotEmpty) 'su': qp['subject']!,
      if ((qp['body'] ?? '').isNotEmpty) 'body': qp['body']!,
      if ((qp['cc'] ?? '').isNotEmpty) 'cc': qp['cc']!,
      if ((qp['bcc'] ?? '').isNotEmpty) 'bcc': qp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', params);
  }

  static String dhDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');
}

// ============================================================================
// Сервис открытия ссылок: DhLinker (бывший DressRetroLinker)
// ============================================================================

class DhLinker {
  static Future<bool> dhOpen(Uri uri) async {
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
      debugPrint('DressRetroLinker error: $error; url=$uri');
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
}

// ============================================================================
// Bank helpers (из первого main.dart)
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
    debugPrint('dhOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// FCM Background Handler
// ============================================================================

@pragma('vm:entry-point')
Future<void> dhFcmBackgroundHandler(RemoteMessage message) async {
  debugPrint("Spin ID: ${message.messageId}");
  debugPrint("Spin Data: ${message.data}");
}

// ============================================================================
// DhDeviceProfile (бывший DressRetroDeviceProfile)
// ============================================================================

class DhDeviceProfile {
  String? dhDeviceId;
  String? dhSessionId = 'wheel-one-off';
  String? dhPlatformKind;
  String? dhOsBuild;
  String? dhAppVersion;
  String? dhLocaleCode;
  String? dhTimezoneName;
  bool dhPushEnabled = true;

  // Новый UA из WebView
  String? dhBaseUserAgent;

  // Для SafeArea
  bool dhSafeAreaEnabled = false;
  String? dhSafeAreaColor;

  Future<void> dhInitialize() async {
    try {
      DhTimezoneData.initializeTimeZones();
    } catch (_) {}

    final DeviceInfoPlugin infoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo androidInfo =
      await infoPlugin.androidInfo;
      dhDeviceId = androidInfo.id;
      dhPlatformKind = 'android';
      dhOsBuild = androidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo iosInfo = await infoPlugin.iosInfo;
      dhDeviceId = iosInfo.identifierForVendor;
      dhPlatformKind = 'ios';
      dhOsBuild = iosInfo.systemVersion;
    }

    final PackageInfo packageInfo = await PackageInfo.fromPlatform();
    dhAppVersion = packageInfo.version;
    dhLocaleCode = Platform.localeName.split('_').first;
    dhTimezoneName = DhTimezone.local.name;
    dhSessionId = 'wheel-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> dhAsMap({String? dhFcmToken}) => <String, dynamic>{
    'fcm_token': dhFcmToken ?? 'missing_token',
    'device_id': dhDeviceId ?? 'missing_id',
    'app_name': 'diaryh',
    'instance_id': dhSessionId ?? 'missing_session',
    'platform': dhPlatformKind ?? 'missing_system',
    'os_version': dhOsBuild ?? 'missing_build',
    'app_version': dhAppVersion ?? 'missing_app',
    'language': dhLocaleCode ?? 'en',
    'timezone': dhTimezoneName ?? 'UTC',
    'push_enabled': dhPushEnabled,
    'fthcashier': 'true',
    'safearea': dhSafeAreaEnabled,
    'safearea_color': dhSafeAreaColor ?? '',
    'base_ua': dhBaseUserAgent ?? '',
  };
}

// ============================================================================
// AppsFlyer шпион: DhSpy (бывший DressRetroSpy)
// ============================================================================

class DhSpy {
  AppsFlyerOptions? dhOptions;
  AppsflyerSdk? dhSdk;

  String dhAppsFlyerUid = '';
  String dhAppsFlyerData = '';

  void dhStart({VoidCallback? dhOnUpdate}) {
    final AppsFlyerOptions opts = AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6756072063',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    dhOptions = opts;
    dhSdk = AppsflyerSdk(opts);

    dhSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    dhSdk?.startSDK(
      onSuccess: () =>
          DhVault().dhLoggerInstance.dhLogInfo('WheelSpy started'),
      onError: (code, msg) => DhVault()
          .dhLoggerInstance
          .dhLogError('WheelSpy error $code: $msg'),
    );

    dhSdk?.onInstallConversionData((value) {
      dhAppsFlyerData = value.toString();
      dhOnUpdate?.call();
    });

    dhSdk?.getAppsFlyerUID().then((value) {
      dhAppsFlyerUid = value.toString();
      dhOnUpdate?.call();
    });
  }
}

// ============================================================================
// Мост для FCM токена: DhFcmBridge (бывший DressRetroFcmBridge)
// ============================================================================

class DhFcmBridge {
  final DhLogger dhLog = const DhLogger();
  String? dhToken;
  final List<void Function(String)> dhWaiters = <void Function(String)>[];

  String? get dhCurrentToken => dhToken;

  DhFcmBridge() {
    const MethodChannel('com.example.fcm/token')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setToken') {
        final String tokenString = call.arguments as String;
        if (tokenString.isNotEmpty) {
          dhSetToken(tokenString);
        }
      }
    });

    dhRestoreToken();
  }

  Future<void> dhRestoreToken() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? cached = prefs.getString(dhCachedFcmKey);
      if (cached != null && cached.isNotEmpty) {
        dhSetToken(cached, notify: false);
      }
    } catch (_) {}
  }

  Future<void> dhPersistToken(String newToken) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(dhCachedFcmKey, newToken);
    } catch (_) {}
  }

  void dhSetToken(
      String newToken, {
        bool notify = true,
      }) {
    dhToken = newToken;
    dhPersistToken(newToken);
    if (notify) {
      for (final void Function(String) callback
      in List<void Function(String)>.from(dhWaiters)) {
        try {
          callback(newToken);
        } catch (err) {
          dhLog.dhLogWarn('fcm waiter error: $err');
        }
      }
      dhWaiters.clear();
    }
  }

  Future<void> dhWaitForToken(
      Function(String tokenValue) onToken,
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

      dhWaiters.add(onToken);
    } catch (err) {
      dhLog.dhLogError('wheelWaitToken error: $err');
    }
  }
}

// ============================================================================
// DhLoader (новый лоадер)
// ============================================================================

class DhLoader extends StatefulWidget {
  const DhLoader({Key? key}) : super(key: key);

  @override
  State<DhLoader> createState() => _DhLoaderState();
}

class _DhLoaderState extends State<DhLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController dhController;

  static const Color dhBackgroundColor = Color(0xFF05071B);

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));
    dhController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    dhController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: dhBackgroundColor,
      child: AnimatedBuilder(
        animation: dhController,
        builder: (BuildContext context, Widget? child) {
          final double phase = dhController.value * 2 * DhMath.pi;
          return CustomPaint(
            painter: DhLoaderPainter(
              dhPhase: phase,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class DhLoaderPainter extends CustomPainter {
  final double dhPhase;

  DhLoaderPainter({
    required this.dhPhase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double width = size.width;
    final double height = size.height;

    final Paint backgroundPaint = Paint()
      ..color = const Color(0xFF05071B)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, backgroundPaint);

    final double pulse = (DhMath.sin(dhPhase) + 1) / 2;

    final Paint circlePaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.red.withOpacity(0.14 + 0.16 * pulse),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(width * 0.5, height * 0.45),
          radius: height * (0.4 + 0.15 * pulse),
        ),
      );

    canvas.drawCircle(
      Offset(width * 0.5, height * 0.45),
      height * (0.4 + 0.15 * pulse),
      circlePaint,
    );

    final Paint outerPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = RadialGradient(
        colors: <Color>[
          Colors.redAccent.withOpacity(0.10 + 0.10 * (1 - pulse)),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: Offset(width * 0.5, height * 0.45),
          radius: height * (0.55 + 0.10 * (1 - pulse)),
        ),
      );
    canvas.drawCircle(
      Offset(width * 0.5, height * 0.45),
      height * (0.55 + 0.10 * (1 - pulse)),
      outerPaint,
    );

    final double baseSize = width * 0.35;
    final double fontSize =
        baseSize + pulse * (baseSize * 0.15);

    const String letter = 'N';
    const String word = 'CUP';

    final TextPainter letterPainter = TextPainter(
      text: TextSpan(
        text: letter,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          color: Colors.red.shade600,
          letterSpacing: 4,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.8),
              blurRadius: 22 + 18 * pulse,
              offset: const Offset(0, 0),
            ),
            Shadow(
              color: Colors.black.withOpacity(0.8),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

    final double letterX = (width - letterPainter.width) / 2;
    final double letterY = (height - letterPainter.height) / 2;

    final Offset letterOffset = Offset(letterX, letterY);

    final Rect letterRect = Rect.fromCenter(
      center: Offset(width / 2, height / 2),
      width: letterPainter.width * 1.4,
      height: letterPainter.height * 1.6,
    );

    final Paint glowPaint = Paint()
      ..maskFilter = MaskFilter.blur(
        BlurStyle.normal,
        28 + 24 * pulse,
      )
      ..color = Colors.red.withOpacity(0.7 + 0.2 * pulse);

    canvas.saveLayer(letterRect, glowPaint);
    letterPainter.paint(canvas, letterOffset);
    canvas.restore();

    letterPainter.paint(canvas, letterOffset);

    final double cupFontSize = width * 0.11;

    final TextPainter cupPainterReal = TextPainter(
      text: TextSpan(
        text: word,
        style: TextStyle(
          fontSize: cupFontSize,
          fontWeight: FontWeight.w600,
          color: Colors.red.shade100.withOpacity(0.95),
          letterSpacing: 5,
          shadows: <Shadow>[
            Shadow(
              color: Colors.redAccent.withOpacity(0.7),
              blurRadius: 12 + 10 * pulse,
              offset: const Offset(0, 0),
            ),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

    final double cupX = (width - cupPainterReal.width) / 2;
    final double cupY =
        letterY + letterPainter.height + height * 0.03;

    final Offset cupOffset = Offset(cupX, cupY);
    cupPainterReal.paint(canvas, cupOffset);
  }

  @override
  bool shouldRepaint(covariant DhLoaderPainter oldDelegate) =>
      oldDelegate.dhPhase != dhPhase;
}

// ============================================================================
// Статистика (DhFinalUrl / DhPostStat) — строки не меняем
// ============================================================================

Future<String> dhFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient client = HttpClient();

  try {
    Uri currentUri = Uri.parse(startUrl);

    for (int i = 0; i < maxHops; i++) {
      final HttpClientRequest request =
      await client.getUrl(currentUri);
      request.followRedirects = false;
      final HttpClientResponse response = await request.close();

      if (response.isRedirect) {
        final String? loc =
        response.headers.value(HttpHeaders.locationHeader);
        if (loc == null || loc.isEmpty) break;

        final Uri nextUri = Uri.parse(loc);
        currentUri = nextUri.hasScheme
            ? nextUri
            : currentUri.resolveUri(nextUri);
        continue;
      }

      return currentUri.toString();
    }

    return currentUri.toString();
  } catch (error) {
    debugPrint('wheelFinalUrl error: $error');
    return startUrl;
  } finally {
    client.close(force: true);
  }
}

Future<void> dhPostStat({
  required String dhEvent,
  required int dhTimeStart,
  required String dhUrl,
  required int dhTimeFinish,
  required String dhAppSid,
  int? dhFirstPageTs,
}) async {
  try {
    final String resolvedUrl = await dhFinalUrl(dhUrl);
    final Map<String, dynamic> payload = <String, dynamic>{
      'event': dhEvent,
      'timestart': dhTimeStart,
      'timefinsh': dhTimeFinish,
      'url': resolvedUrl,
      'appleID': '6755681349',
      'open_count': '$dhAppSid/$dhTimeStart',
    };

    debugPrint('wheelStat $payload');

    final http.Response resp = await http.post(
      Uri.parse('$dhStatEndpoint/$dhAppSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    );

    debugPrint('wheelStat resp=${resp.statusCode} body=${resp.body}');
  } catch (error) {
    debugPrint('wheelPostStat error: $error');
  }
}

// ============================================================================
// WebView-экран: DhTableView (бывший DressRetroTableView)
// SafeArea + SafeArea color + localStorage подхватываются из SharedPreferences
// ============================================================================

class DhTableView extends StatefulWidget with WidgetsBindingObserver {
  String dhStartingUrl;
  DhTableView(this.dhStartingUrl, {super.key});

  @override
  State<DhTableView> createState() => _DhTableViewState(dhStartingUrl);
}

class _DhTableViewState extends State<DhTableView>
    with WidgetsBindingObserver {
  _DhTableViewState(this.dhCurrentUrl);

  final DhVault dhVaultInstance = DhVault();

  late InAppWebViewController dhWebViewController;
  String? dhPushToken;
  final DhDeviceProfile dhDeviceProfileInstance = DhDeviceProfile();
  final DhSpy dhSpyInstance = DhSpy();

  bool dhOverlayBusy = false;
  String dhCurrentUrl;
  DateTime? dhLastPausedAt;

  bool dhLoadedOnceSent = false;
  int? dhFirstPageTimestamp;
  int dhStartLoadTimestamp = 0;

  // --------- Социальные / внешние хосты / схемы ---------

  final Set<String> dhExternalHosts = <String>{
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

  final Set<String> dhExternalSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'bnl',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
  };

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

  // --------- UserAgent + SafeArea ---------

  String? _baseUserAgent;
  String _currentUserAgent = '';
  String? _serverUserAgent;
  bool _isInGoogleAuth = false;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = Colors.black;

  // --------- POPUP (window.open) ---------

  InAppWebViewController? _popupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;
  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(dhFcmBackgroundHandler);

    dhFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    // 1) SafeArea state (enabled + color) подхватываем из SharedPreferences
    _loadSafeAreaFromPrefs();

    // 2) Push
    dhInitPushAndGetToken();

    // 3) Профиль устройства -> localStorage + SharedPreferences (app_data)
    dhDeviceProfileInstance.dhInitialize().then((_) async {
      if (!mounted) return;
      await _updateLocalStorage();
    });

    // 4) FCM + AppsFlyer
    dhWireForegroundPushHandlers();
    dhBindPlatformNotificationTap();
    dhSpyInstance.dhStart(dhOnUpdate: () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      dhLastPausedAt = DateTime.now();
    }
    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && dhLastPausedAt != null) {
        final DateTime now = DateTime.now();
        final Duration drift = now.difference(dhLastPausedAt!);
        if (drift > const Duration(minutes: 25)) {
          dhForceReloadToLobby();
        }
      }
      dhLastPausedAt = null;
    }
  }

  void dhForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration duration) {
      if (!mounted) return;
      // здесь можно вернуть в MafiaHarbor/CaptainHarbor/BillHarbor при необходимости
    });
  }

  // --------------------------------------------------------------------------
  // Push / FCM
  // --------------------------------------------------------------------------

  void dhWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
      if (msg.data['uri'] != null) {
        dhNavigateTo(msg.data['uri'].toString());
      } else {
        dhReturnToCurrentUrl();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage msg) {
      if (msg.data['uri'] != null) {
        dhNavigateTo(msg.data['uri'].toString());
      } else {
        dhReturnToCurrentUrl();
      }
    });
  }

  void dhNavigateTo(String newUrl) async {
    await dhWebViewController.loadUrl(
      urlRequest: URLRequest(url: WebUri(newUrl)),
    );
  }

  void dhReturnToCurrentUrl() async {
    Future<void>.delayed(const Duration(seconds: 3), () {
      dhWebViewController.loadUrl(
        urlRequest: URLRequest(url: WebUri(dhCurrentUrl)),
      );
    });
  }

  Future<void> dhInitPushAndGetToken() async {
    final FirebaseMessaging fm = FirebaseMessaging.instance;
    await fm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    dhPushToken = await fm.getToken();
  }

  // --------------------------------------------------------------------------
  // Привязка канала: тап по уведомлению из native
  // --------------------------------------------------------------------------

  void dhBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == "onNotificationTap") {
        final Map<String, dynamic> payload =
        Map<String, dynamic>.from(call.arguments);
        debugPrint("URI from platform tap: ${payload['uri']}");
        final String? uriString = payload["uri"]?.toString();
        if (uriString != null && !uriString.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) =>
                  DhTableView(uriString),
            ),
                (Route<dynamic> route) => false,
          );
        }
      }
    });
  }

  // --------------------------------------------------------------------------
  // localStorage + SharedPreferences: профиль устройства
  // --------------------------------------------------------------------------

  /// Обновляем app_data в localStorage И синхронно сохраняем JSON в SharedPreferences
  Future<void> _updateLocalStorage() async {
    try {
      final Map<String, dynamic> data =
      dhDeviceProfileInstance.dhAsMap(dhFcmToken: dhPushToken);

      final String json = jsonEncode(data);

      // 1) В localStorage WebView
      await dhWebViewController.evaluateJavascript(
        source: "localStorage.setItem('app_data', JSON.stringify($json));",
      );

      // 2) В SharedPreferences (чтобы при следующем запуске можно было восстановить)
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_data', json);

      dhVaultInstance.dhLoggerInstance
          .dhLogInfo('app_data saved to localStorage & SharedPreferences: $json');
    } catch (e, st) {
      dhVaultInstance.dhLoggerInstance
          .dhLogError('updateLocalStorage error: $e\n$st');
    }
  }

  /// Восстанавливаем app_data из SharedPreferences обратно в localStorage
  Future<void> _restoreAppDataFromPrefsToLocalStorage() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? savedJson = prefs.getString('app_data');
      if (savedJson == null || savedJson.isEmpty) {
        return;
      }

      final String js =
          "localStorage.setItem('app_data', JSON.stringify($savedJson));";

      await dhWebViewController.evaluateJavascript(source: js);

      dhVaultInstance.dhLoggerInstance.dhLogInfo(
          'app_data restored from SharedPreferences to localStorage: $savedJson');
    } catch (e, st) {
      dhVaultInstance.dhLoggerInstance.dhLogError(
          '_restoreAppDataFromPrefsToLocalStorage error: $e\n$st');
    }
  }

  // --------------------------------------------------------------------------
  // UserAgent / SafeArea helpers
  // --------------------------------------------------------------------------

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google');
  }

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua =
        await dhWebViewController.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          dhDeviceProfileInstance.dhBaseUserAgent = _baseUserAgent;
          dhVaultInstance.dhLoggerInstance
              .dhLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        dhVaultInstance.dhLoggerInstance
            .dhLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      dhVaultInstance.dhLoggerInstance
          .dhLogWarn('Base User-Agent is null, skip UA update');
      return;
    }

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = _baseUserAgent!;
    }

    _serverUserAgent = newUa;
    dhVaultInstance.dhLoggerInstance
        .dhLogInfo('Server UA calculated: $_serverUserAgent');
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

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (_isInGoogleAuth) {
      dhVaultInstance.dhLoggerInstance.dhLogInfo(
          'Skip normal UA apply because we are in Google auth');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) return;

    try {
      await dhWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      debugPrint('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      dhVaultInstance.dhLoggerInstance
          .dhLogError('Error while setting UA "$targetUa": $e');
    }
  }

  Future<void> _addRandomToUserAgentForGoogle() async {
    const String targetUa = 'random';
    if (_currentUserAgent == targetUa && _isInGoogleAuth) return;

    try {
      await dhWebViewController.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      _isInGoogleAuth = true;
      debugPrint('[UA] GOOGLE RANDOM USER AGENT: $_currentUserAgent');
    } catch (e) {
      dhVaultInstance.dhLoggerInstance
          .dhLogError('Error setting RANDOM UA for Google: $e');
    }
  }

  Future<void> _restoreUserAgentAfterGoogleIfNeeded() async {
    if (!_isInGoogleAuth) return;
    _isInGoogleAuth = false;
    await _applyNormalUserAgentIfNeeded();
  }

  // Хелпер для парсинга HEX‑цвета (общий для SafeArea и prefs)
  Color _parseHexColor(String hex, {Color fallback = const Color(0xFF1A1A22)}) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) value = 'FF$value';
    final intColor = int.tryParse(value, radix: 16);
    if (intColor == null) return fallback;
    return Color(intColor);
  }

  // НОВОЕ: загрузка SafeArea из SharedPreferences при старте
  Future<void> _loadSafeAreaFromPrefs() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool enabled = prefs.getBool(dhSafeAreaEnabledKey) ?? false;
      final String colorHex = prefs.getString(dhSafeAreaColorKey) ?? '';

      Color bg = Colors.black;
      if (enabled) {
        if (colorHex.isNotEmpty) {
          bg = _parseHexColor(colorHex, fallback: const Color(0xFF1A1A22));
        } else {
          bg = const Color(0xFF1A1A22);
        }
      }

      if (!mounted) return;

      setState(() {
        _safeAreaEnabled = enabled;
        _safeAreaBackgroundColor = bg;
        dhDeviceProfileInstance.dhSafeAreaEnabled = enabled;
        dhDeviceProfileInstance.dhSafeAreaColor =
        enabled ? (colorHex.isNotEmpty ? colorHex : '#1A1A22') : '';
      });

      dhVaultInstance.dhLoggerInstance.dhLogInfo(
          'SafeArea loaded from prefs: enabled=$enabled, color="$colorHex"');
    } catch (e, st) {
      dhVaultInstance.dhLoggerInstance
          .dhLogError('_loadSafeAreaFromPrefs error: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
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

    if (safearea == null) return;

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    Color background = safearea ? const Color(0xFF1A1A22) : Colors.black;

    if (safearea && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex, fallback: const Color(0xFF1A1A22));
    }

    setState(() {
      _safeAreaEnabled = safearea!;
      _safeAreaBackgroundColor = background;
      dhDeviceProfileInstance.dhSafeAreaEnabled = safearea;
      dhDeviceProfileInstance.dhSafeAreaColor =
      safearea ? (chosenHex ?? '#1A1A22') : '';
    });

    // НОВОЕ: сохраняем SafeArea в SharedPreferences при каждом обновлении
    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool(dhSafeAreaEnabledKey, safearea!);
        await prefs.setString(
          dhSafeAreaColorKey,
          dhDeviceProfileInstance.dhSafeAreaColor ?? '',
        );
        dhVaultInstance.dhLoggerInstance.dhLogInfo(
          'SafeArea saved to prefs: enabled=$safearea, color="${dhDeviceProfileInstance.dhSafeAreaColor}"',
        );
      } catch (e, st) {
        dhVaultInstance.dhLoggerInstance
            .dhLogError('Error saving SafeArea to prefs: $e\n$st');
      }
    }();
  }

  // --------------------------------------------------------------------------
  // POPUP helpers
  // --------------------------------------------------------------------------

  InAppWebViewSettings _popupSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
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

  void _openPopup(CreateWindowAction req, {String? urlString}) {
    setState(() {
      _popupCreateAction = req;
      _popupUrl = (urlString != null && urlString.isNotEmpty)
          ? urlString
          : req.request.url?.toString();
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      _popupWebViewController = null;
    });
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = _popupWebViewController;
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
    } catch (_) {}
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = _popupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 200), () {
          _refreshPopupCanGoBack();
        });
      } else {
        _closePopup();
      }
    } catch (_) {
      _closePopup();
    }
  }

  Widget _buildPopupOverlay() {
    if (!_isPopupVisible || (_popupUrl == null && _popupCreateAction == null)) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            SafeArea(
              bottom: false,
              child: Container(
                color: Colors.black,
                height: 48,
                child: Row(
                  children: [
                    if (_popupCanGoBack)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: _handlePopupBackPressed,
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: _closePopup,
                      ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null && _popupUrl != null)
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupSettings(),
                onWebViewCreated: (InAppWebViewController controller) async {
                  _popupWebViewController = controller;
                },
                onLoadStart: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStop: (controller, uri) async {
                  if (uri != null) {
                    setState(() {
                      _popupCurrentUrl = uri.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory:
                    (controller, url, isReload) async {
                  if (url != null) {
                    setState(() {
                      _popupCurrentUrl = url.toString();
                    });
                  }
                  await _refreshPopupCanGoBack();
                },
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction nav,
                    ) async {
                  final Uri? uri = nav.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (DhKit.dhLooksLikeBareMail(uri)) {
                    final Uri mailto = DhKit.dhToMailto(uri);
                    await DhLinker.dhOpen(DhKit.dhGmailize(mailto));
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await DhLinker.dhOpen(DhKit.dhGmailize(uri));
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(
                      uri,
                      mode: LaunchMode.externalApplication,
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (dhIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          dhIsBankDomain(uri))) {
                    await dhOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  _closePopup();
                },
                onDownloadStartRequest: (controller, req) async {
                  await DhLinker.dhOpen(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    dhBindPlatformNotificationTap();

    final bool isDark =
        MediaQuery.of(context).platformBrightness == Brightness.dark;

    final Color bgColor = _safeAreaEnabled
        ? _safeAreaBackgroundColor
        : (isDark ? Colors.black : Colors.white);

    final Widget webView = InAppWebView(
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
        url: WebUri(dhCurrentUrl),
      ),
      onWebViewCreated: (InAppWebViewController controller) async {
        dhWebViewController = controller;

        // Инициализация UA
        try {
          final ua = await controller.evaluateJavascript(
            source: "navigator.userAgent",
          );
          if (ua is String && ua.trim().isNotEmpty) {
            _baseUserAgent = ua.trim();
            _currentUserAgent = _baseUserAgent!;
            dhDeviceProfileInstance.dhBaseUserAgent = _baseUserAgent;
            debugPrint('[UA] INITIAL: $_baseUserAgent');
          }
        } catch (e) {
          dhVaultInstance.dhLoggerInstance
              .dhLogWarn('Failed to read navigator.userAgent: $e');
        }

        await _applyNormalUserAgentIfNeeded();

        // После создания WebView — актуализируем localStorage
        await _updateLocalStorage();

        // Через 6 секунд после открытия экрана — восстановление app_data из SharedPreferences
        Future<void>.delayed(const Duration(seconds: 6), () async {
          if (!mounted) return;
          await _restoreAppDataFromPrefsToLocalStorage();
        });

        dhWebViewController.addJavaScriptHandler(
          handlerName: 'onServerResponse',
          callback: (List<dynamic> args) {
            dhVaultInstance.dhLoggerInstance
                .dhLogInfo("JS Args: $args");

            try {
              dynamic first = args.isNotEmpty ? args[0] : null;

              if (first is List && first.isNotEmpty) {
                first = first.first;
              }

              if (first is Map) {
                final Map<dynamic, dynamic> root = first;

                // safearea + userAgent из сервера
                _updateSafeAreaFromServerPayload(root);
                _updateUserAgentFromServerPayload(root);
                _applyNormalUserAgentIfNeeded();

                // При каждом ответе сервера можно обновлять localStorage
                _updateLocalStorage();
              }

              try {
                return args
                    .reduce((dynamic v, dynamic e) => v + e);
              } catch (_) {
                return args.toString();
              }
            } catch (e) {
              return args.toString();
            }
          },
        );
      },
      onLoadStart: (
          InAppWebViewController controller,
          Uri? uri,
          ) async {
        dhStartLoadTimestamp = DateTime.now().millisecondsSinceEpoch;

        if (uri != null) {
          if (_isGoogleUrl(uri)) {
            await _addRandomToUserAgentForGoogle();
          } else {
            await _restoreUserAgentAfterGoogleIfNeeded();
            await _applyNormalUserAgentIfNeeded();
          }

          if (DhKit.dhLooksLikeBareMail(uri)) {
            try {
              await controller.stopLoading();
            } catch (_) {}
            final Uri mailto = DhKit.dhToMailto(uri);
            await DhLinker.dhOpen(
              DhKit.dhGmailize(mailto),
            );
            return;
          }

          // банки
          if (dhIsBankScheme(uri) ||
              ((uri.scheme == 'http' || uri.scheme == 'https') &&
                  dhIsBankDomain(uri))) {
            try {
              await controller.stopLoading();
            } catch (_) {}
            await dhOpenBank(uri);
            return;
          }

          final String scheme = uri.scheme.toLowerCase();
          if (scheme != 'http' && scheme != 'https') {
            try {
              await controller.stopLoading();
            } catch (_) {}
          }
        }
      },
      onLoadStop: (
          InAppWebViewController controller,
          Uri? uri,
          ) async {
        await controller.evaluateJavascript(
          source: "console.log('Hello from Roulette JS!');",
        );

        setState(() {
          dhCurrentUrl = uri?.toString() ?? dhCurrentUrl;
        });

        await _restoreUserAgentAfterGoogleIfNeeded();
        await _applyNormalUserAgentIfNeeded();

        // После полной загрузки страницы обновляем localStorage
        await _updateLocalStorage();

        // И сразу тянем app_data из SharedPreferences в localStorage
        await _restoreAppDataFromPrefsToLocalStorage();

        Future<void>.delayed(const Duration(seconds: 20), () {
          dhSendLoadedOnce();
        });
      },
      shouldOverrideUrlLoading: (
          InAppWebViewController controller,
          NavigationAction nav,
          ) async {
        final Uri? uri = nav.request.url;
        if (uri == null) {
          return NavigationActionPolicy.ALLOW;
        }

        if (_isGoogleUrl(uri)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (DhKit.dhLooksLikeBareMail(uri)) {
          final Uri mailto = DhKit.dhToMailto(uri);
          await DhLinker.dhOpen(
            DhKit.dhGmailize(mailto),
          );
          return NavigationActionPolicy.CANCEL;
        }

        final String scheme = uri.scheme.toLowerCase();

        if (scheme == 'mailto') {
          await DhLinker.dhOpen(
            DhKit.dhGmailize(uri),
          );
          return NavigationActionPolicy.CANCEL;
        }

        if (dhIsBankScheme(uri) ||
            ((scheme == 'http' || scheme == 'https') &&
                dhIsBankDomain(uri))) {
          await dhOpenBank(uri);
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
        final bool isSocial = host.endsWith('facebook.com') ||
            host.endsWith('instagram.com') ||
            host.endsWith('twitter.com') ||
            host.endsWith('x.com');

        if (isSocial) {
          await DhLinker.dhOpen(uri);
          return NavigationActionPolicy.CANCEL;
        }

        if (dhIsExternalDestination(uri)) {
          final Uri mapped = dhMapExternalToHttp(uri);
          await DhLinker.dhOpen(mapped);
          return NavigationActionPolicy.CANCEL;
        }

        if (scheme != 'http' && scheme != 'https') {
          return NavigationActionPolicy.CANCEL;
        }

        return NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (
          InAppWebViewController controller,
          CreateWindowAction req,
          ) async {
        final Uri? url = req.request.url;
        if (url == null) return false;

        if (_isGoogleUrl(url)) {
          await _addRandomToUserAgentForGoogle();
        } else {
          await _restoreUserAgentAfterGoogleIfNeeded();
          await _applyNormalUserAgentIfNeeded();
        }

        if (DhKit.dhLooksLikeBareMail(url)) {
          final Uri mail = DhKit.dhToMailto(url);
          await DhLinker.dhOpen(
            DhKit.dhGmailize(mail),
          );
          return false;
        }

        final String scheme = url.scheme.toLowerCase();

        if (scheme == 'mailto') {
          await DhLinker.dhOpen(
            DhKit.dhGmailize(url),
          );
          return false;
        }

        if (dhIsBankScheme(url) ||
            ((scheme == 'http' || scheme == 'https') &&
                dhIsBankDomain(url))) {
          await dhOpenBank(url);
          return false;
        }

        if (scheme == 'tel') {
          await launchUrl(
            url,
            mode: LaunchMode.externalApplication,
          );
          return false;
        }

        final String host = url.host.toLowerCase();
        final bool isSocial = host.endsWith('facebook.com') ||
            host.endsWith('instagram.com') ||
            host.endsWith('twitter.com') ||
            host.endsWith('x.com');

        if (isSocial) {
          await DhLinker.dhOpen(url);
          return false;
        }

        if (dhIsExternalDestination(url)) {
          final Uri mapped = dhMapExternalToHttp(url);
          await DhLinker.dhOpen(mapped);
          return false;
        }

        // popup-логика: всё, что осталось http/https — открываем во всплывающем WebView
        if (scheme == 'http' || scheme == 'https') {
          _openPopup(req, urlString: url.toString());
          return true; // говорим WebView, что создаём окно сами
        }

        return false;
      },
    );

    final Widget body = Stack(
      children: <Widget>[
        webView,
        if (dhOverlayBusy)
          const Positioned.fill(
            child: ColoredBox(
              color: Colors.black87,
              child: Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        _buildPopupOverlay(),
      ],
    );

    final Widget wrapped = _safeAreaEnabled ? SafeArea(child: body) : body;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: bgColor,
        body: wrapped,
      ),
    );
  }

  // ========================================================================
  // Внешние “столы” (протоколы/мессенджеры/соцсети)
  // ========================================================================

  bool dhIsExternalDestination(Uri uri) {
    final String scheme = uri.scheme.toLowerCase();
    if (dhExternalSchemes.contains(scheme)) {
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

  Uri dhMapExternalToHttp(Uri uri) {
    final String scheme = uri.scheme.toLowerCase();

    if (scheme == 'tg' || scheme == 'telegram') {
      final Map<String, String> qp = uri.queryParameters;
      final String? domain = qp['domain'];
      if (domain != null && domain.isNotEmpty) {
        return Uri.https('t.me', '/$domain', <String, String>{
          if (qp['start'] != null) 'start': qp['start']!,
        });
      }
      final String path = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        't.me',
        '/$path',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (scheme == 'whatsapp') {
      final Map<String, String> qp = uri.queryParameters;
      final String? phone = qp['phone'];
      final String? text = qp['text'];
      if (phone != null && phone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${DhKit.dhDigitsOnly(phone)}',
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

  Future<void> dhSendLoadedOnce() async {
    if (dhLoadedOnceSent) {
      debugPrint('Wheel Loaded already sent, skip');
      return;
    }

    final int now = DateTime.now().millisecondsSinceEpoch;

    await dhPostStat(
      dhEvent: 'Loaded',
      dhTimeStart: dhStartLoadTimestamp,
      dhTimeFinish: now,
      dhUrl: dhCurrentUrl,
      dhAppSid: dhSpyInstance.dhAppsFlyerUid,
      dhFirstPageTs: dhFirstPageTimestamp,
    );

    dhLoadedOnceSent = true;
  }
}