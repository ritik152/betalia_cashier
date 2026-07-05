import 'dart:async';
import 'dart:convert';
import 'package:betalia_cashier/screens/webview_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ── Global Error Store ────────────────────────────────────────────────────────
/// Collects all unhandled errors for on-screen debug display.
/// Only populated in debug mode — empty in release builds.
final List<_DebugError> debugErrors = [];
final int _maxDebugErrors = 50;

class _DebugError {
  final DateTime timestamp;
  final String source;
  final String message;
  final String? details;

  _DebugError({
    required this.timestamp,
    required this.source,
    required this.message,
    this.details,
  });
}

void _addDebugError(String source, String message, [String? details]) {
  if (!kDebugMode) return;
  debugErrors.insert(
    0,
    _DebugError(
      timestamp: DateTime.now(),
      source: source,
      message: message,
      details: details,
    ),
  );
  if (debugErrors.length > _maxDebugErrors) {
    debugErrors.removeRange(_maxDebugErrors, debugErrors.length);
  }
}

// ── Main Entry ────────────────────────────────────────────────────────────────
void main() {
  // ── Global error handlers (prevent crashes, show errors instead) ──
  FlutterError.onError = (FlutterErrorDetails details) {
    // Log to console
    FlutterError.presentError(details);

    // Store for debug overlay
    _addDebugError(
      'Flutter',
      details.exceptionAsString(),
      details.stack?.toString(),
    );

    // In debug mode, DON'T crash — just log
    if (kDebugMode) {
      // Prevent the red screen of death, allow the app to continue
      return;
    }
  };

  // Catch all unhandled async errors
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('═══════════════════════════════════════════════════════');
    debugPrint('UNHANDLED ASYNC ERROR: $error');
    debugPrint('${stack ?? StackTrace.empty}');
    debugPrint('═══════════════════════════════════════════════════════');

    _addDebugError(
      'Async',
      error.toString(),
      stack?.toString(),
    );

    // Return true to prevent crash in debug mode
    return kDebugMode;
  };

  WidgetsFlutterBinding.ensureInitialized();

  // Hide status bar and navigation bar
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Betalia Cashier',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
      ),
      home: const DebugErrorWrapper(child: WebViewScreen()),
    );
  }
}

// ── Debug Error Overlay ───────────────────────────────────────────────────────
/// Wraps the app content and shows a debug error panel at the bottom.
/// Only rendered in debug mode.
class DebugErrorWrapper extends StatefulWidget {
  final Widget child;
  const DebugErrorWrapper({super.key, required this.child});

  @override
  State<DebugErrorWrapper> createState() => _DebugErrorWrapperState();
}

class _DebugErrorWrapperState extends State<DebugErrorWrapper> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // Refresh when new errors arrive
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {});
    });
  }

  void _handleErrorAdded() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode || debugErrors.isEmpty) return widget.child;

    return Stack(
      children: [
        // Main app content
        Positioned.fill(child: widget.child),

        // Debug error panel at bottom
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            child: GestureDetector(
              onTap: () {
                setState(() => _expanded = !_expanded);
              },
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: _expanded ? 300 : 40,
                ),
                decoration: BoxDecoration(
                  color: Colors.yellow.shade900.withAlpha(240),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(8),
                    topRight: Radius.circular(8),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Collapsed header
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded,
                              color: Colors.yellow, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            '${debugErrors.length} Debug Error${debugErrors.length != 1 ? 's' : ''}',
                            style: const TextStyle(
                              color: Colors.yellow,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            _expanded ? '▼ Collapse' : '▲ Expand',
                            style: const TextStyle(color: Colors.yellow, fontSize: 11),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () {
                              debugErrors.clear();
                              setState(() => _expanded = false);
                            },
                            child: const Text(
                              'Clear',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Expanded error list
                    if (_expanded)
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: debugErrors.length,
                          itemBuilder: (context, index) {
                            final error = debugErrors[index];
                            final time =
                                '${error.timestamp.hour.toString().padLeft(2, '0')}:${error.timestamp.minute.toString().padLeft(2, '0')}:${error.timestamp.second.toString().padLeft(2, '0')}';
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                      color: Colors.yellow.withAlpha(60)),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: Colors.red.withAlpha(80),
                                          borderRadius:
                                              BorderRadius.circular(3),
                                        ),
                                        child: Text(
                                          error.source,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        time,
                                        style: TextStyle(
                                          color: Colors.yellow.withAlpha(180),
                                          fontSize: 9,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    error.message,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}