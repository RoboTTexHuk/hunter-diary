import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'main.dart';

class LuckyHunterHelpLite extends StatefulWidget {
  const LuckyHunterHelpLite({super.key});

  @override
  State<LuckyHunterHelpLite> createState() => _LuckyHunterHelpLiteState();
}

class _LuckyHunterHelpLiteState extends State<LuckyHunterHelpLite> {
  InAppWebViewController? luckyHunterWebViewController;
  bool luckyHunterLoading = true;

  Future<bool> luckyHunterGoBackInWebViewIfPossible() async {
    if (luckyHunterWebViewController == null) return false;
    try {
      final bool luckyHunterCanBack =
      await luckyHunterWebViewController!.canGoBack();
      if (luckyHunterCanBack) {
        await luckyHunterWebViewController!.goBack();
        return true;
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        final bool luckyHunterHandled =
        await luckyHunterGoBackInWebViewIfPossible();
        return luckyHunterHandled ? false : false;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          elevation: 0,
          leading: IconButton(
            tooltip: 'Назад',
            icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
            onPressed: () async {
              final bool luckyHunterHandled =
              await luckyHunterGoBackInWebViewIfPossible();
              if (!luckyHunterHandled) {}
            },
          ),
        ),
        body: SafeArea(
          child: Stack(
            children: <Widget>[
              InAppWebView(
                initialFile: 'assets/lucky.html',
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  supportZoom: false,
                  disableHorizontalScroll: false,
                  disableVerticalScroll: false,
                  transparentBackground: true,
                  mediaPlaybackRequiresUserGesture: false,
                  disableDefaultErrorPage: true,
                  allowsInlineMediaPlayback: true,
                  allowsPictureInPictureMediaPlayback: true,
                  useOnDownloadStart: true,
                  javaScriptCanOpenWindowsAutomatically: true,
                ),
                onWebViewCreated:
                    (InAppWebViewController luckyHunterController) {
                  luckyHunterWebViewController = luckyHunterController;
                },
                onLoadStart: (InAppWebViewController luckyHunterController,
                    Uri? luckyHunterUrl) =>
                    setState(() => luckyHunterLoading = true),
                onLoadStop: (InAppWebViewController luckyHunterController,
                    Uri? luckyHunterUrl) async =>
                    setState(() => luckyHunterLoading = false),
                onLoadError: (InAppWebViewController luckyHunterController,
                    Uri? luckyHunterUrl,
                    int luckyHunterCode,
                    String luckyHunterMessage) =>
                    setState(() => luckyHunterLoading = false),
              ),
              if (luckyHunterLoading)
                const Positioned.fill(
                  child: IgnorePointer(
                    ignoring: true,
                    child: LuckyHunterNeonLoader(),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Неоновый Lucky / Hunter loader
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