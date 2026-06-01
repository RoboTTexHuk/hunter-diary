import 'package:flutter/material.dart';
import 'dart:math' as math;



class HatLoaderScreen extends StatelessWidget {
  const HatLoaderScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: HatLoader(),
    );
  }
}

/// Поместите в pubspec.yaml:
///
/// flutter:
///   assets:
///     - assets/background.png   ← первый PNG (фон со звёздами и лучами)
///     - assets/hat.png          ← второй PNG (шляпа на чёрном)
///
/// Затем скопируйте оба файла в папку assets/ проекта.

class HatLoader extends StatefulWidget {
  const HatLoader({
    super.key,
    this.hatSize = 200.0,
    this.backgroundImage = 'assets/background.png',
    this.hatImage = 'assets/hat.png',
  });

  final double hatSize;
  final String backgroundImage;
  final String hatImage;

  @override
  State<HatLoader> createState() => _HatLoaderState();
}

class _HatLoaderState extends State<HatLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Фон ─────────────────────────────────────────────────────────
        Image.asset(
          widget.backgroundImage,
          fit: BoxFit.cover,
        ),

        // ── Шляпа по центру ─────────────────────────────────────────────
        Center(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final angle = _controller.value * 2 * math.pi;
              final scaleX = math.cos(angle); // Y-axis rotation illusion

              // Glow усиливается в момент «ребра» поворота
              final glowOpacity =
                  (1.0 - scaleX.abs()).clamp(0.0, 1.0) * 0.8;

              return Stack(
                alignment: Alignment.center,
                children: [
                  // Свечение под шляпой
                  Container(
                    width: widget.hatSize * 1.1,
                    height: widget.hatSize * 1.1,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00BFFF)
                              .withOpacity(glowOpacity * 0.7),
                          blurRadius: 70,
                          spreadRadius: 20,
                        ),
                        BoxShadow(
                          color: const Color(0xFFCC0000)
                              .withOpacity(glowOpacity * 0.4),
                          blurRadius: 50,
                          spreadRadius: 10,
                        ),
                      ],
                    ),
                  ),

                  // Шляпа с Y-axis вращением
                  Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..scale(scaleX, 1.0, 1.0),
                    child: child,
                  ),
                ],
              );
            },
            child: Image.asset(
              widget.hatImage,
              width: widget.hatSize,
              height: widget.hatSize,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ],
    );
  }
}
