import 'dart:async';
import 'dart:convert';

import 'package:document_file_save_plus/document_file_save_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:hive/hive.dart';
import 'package:local_assets_server/local_assets_server.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spaces/spaces.dart';
import 'package:yuuna/creator.dart';
import 'package:yuuna/media.dart';
import 'package:yuuna/models.dart';
import 'package:yuuna/pages.dart';
import 'package:yuuna/utils.dart';

/// The media page used for the [ReaderTtuSource].
class ReaderTtuSourcePage extends BaseSourcePage {
  /// Create an instance of this page.
  const ReaderTtuSourcePage({
    super.item,
    super.key,
  });

  @override
  BaseSourcePageState createState() => _ReaderTtuSourcePageState();
}

class _ReaderTtuSourcePageState extends BaseSourcePageState<ReaderTtuSourcePage>
    with WidgetsBindingObserver {
  /// The media source pertaining to this page.
  ReaderTtuSource get mediaSource => ReaderTtuSource.instance;
  bool _controllerInitialised = false;
  late InAppWebViewController _controller;

  DateTime? lastMessageTime;
  Orientation? lastOrientation;

  Duration get consoleMessageDebounce => const Duration(milliseconds: 50);

  final FocusNode _focusNode = FocusNode();
  bool _isRecursiveSearching = false;

  // Secondary (translation) book state
  bool _secondaryShown = false;
  double _splitRatio = 0.5;
  String? _secondaryUrl;
  String? _secondaryTitle;
  bool _hasSecondary = false;
  late Box _readerBox;
  InAppWebViewController? _secondaryController;

  // Edge gesture state
  static const _volumeChannel =
      MethodChannel('app.arianneorpilla.yuuna/volume');
  double _gestureVolume = 0.5;
  double _gestureMaxVolume = 15;
  double _gestureFontSize = 20;
  double _gestureFontSizeSecondary = 20;
  bool _lastFontSwipeWasSecondary = false;
  bool _showVolumeIndicator = false;
  bool _showFontSizeIndicator = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSecondaryBook();
    _initGestureVolume();

    // Pre-warm the in-memory term index for the current language if
    // the user has the "on book open" setting selected (default).
    // Fire-and-forget: the WebView is still loading the book so
    // there's plenty of idle time to build. Skips itself for
    // Japanese (different search path) and bails fast if the index
    // is already built or building in the worker.
    if (appModelNoUpdate.indexPrewarmMode == IndexPrewarmMode.onBookOpen) {
      appModelNoUpdate.prewarmIndex();
    }
  }

  /// Gate yuuna's exit-confirmation dialog on the reader-source
  /// preference. Universal across all books — the toggle lives in
  /// yuuna's TTU settings dialog (cog icon in the reader's bottom
  /// bar), not in TTU's own per-book settings.
  @override
  Future<bool> shouldConfirmExit() async {
    return mediaSource.confirmExit;
  }

  /// Timestamp of the most recent transition from "popup visible" to
  /// "popup hidden." Set from [clearDictionaryResult] below, consumed
  /// by [onWillPop] to close a race on edge-swipe back gestures —
  /// the popup's inner [Dismissible] fires at ~5% of the horizontal
  /// swipe and clears the notifiers before Android delivers the
  /// back event, so by the time `onWillPop` runs the popup looks
  /// closed even though the same physical gesture caused both.
  DateTime? _lastPopupDismissAt;

  /// Close the popup and remember when. Mirrors the base-class
  /// implementation but also clears any WebView-side text selection
  /// (since our content is a WebView, not a Flutter widget) and
  /// stamps the dismiss timestamp for [onWillPop]'s grace window.
  @override
  void clearDictionaryResult() async {
    if (isDictionaryShown || isDictionarySearching) {
      _lastPopupDismissAt = DateTime.now();
    }
    super.clearDictionaryResult();
    unselectWebViewTextSelection(_controller);
  }

  /// Back-button handling, three cases to distinguish:
  ///
  ///   1. Popup currently visible (searching or results on screen).
  ///      Close the popup and stay in the book. Covers the
  ///      tap-a-word-then-press-hardware-back flow.
  ///
  ///   2. Popup *just* dismissed (within the 250 ms grace window)
  ///      because the user performed an edge-swipe back. The
  ///      popup's [Dismissible] wrapper hits its 5% threshold
  ///      long before Android delivers the back event, so both
  ///      notifiers read false here even though the swipe that
  ///      arrived at this callback is the tail of the one that
  ///      closed the popup. Swallow the back so a single gesture
  ///      closes only the popup, not the book underneath.
  ///
  ///   3. Neither — fall through to the usual exit-confirmation
  ///      flow so deliberate exits still work.
  ///
  /// 250 ms is tight enough that a user who dismisses the popup and
  /// then deliberately presses back to exit won't hit case 2 unless
  /// they're unusually fast; human reaction time on a follow-up
  /// press is typically several hundred ms.
  @override
  Future<bool> onWillPop() async {
    if (isDictionaryShown || isDictionarySearching) {
      clearDictionaryResult();
      mediaSource.clearCurrentSentence();
      return false;
    }
    final lastDismiss = _lastPopupDismissAt;
    if (lastDismiss != null &&
        DateTime.now().difference(lastDismiss) <
            const Duration(milliseconds: 250)) {
      // Eat the timestamp so a repeat back press that happens to
      // land just outside the window doesn't also get swallowed
      // because of the original dismiss.
      _lastPopupDismissAt = null;
      return false;
    }
    return super.onWillPop();
  }

  Future<void> _initSecondaryBook() async {
    _readerBox = await Hive.openBox('readerAudio');
    String key = _safeBookKey();
    _secondaryUrl = _readerBox.get('secondary_url_$key');
    _secondaryTitle = _readerBox.get('secondary_title_$key');
    _hasSecondary = _secondaryUrl != null;
    double? ratio = (_readerBox.get('split_ratio_$key') as num?)?.toDouble();
    if (ratio != null) _splitRatio = ratio;
    if (mounted) setState(() {});
  }

  String _safeBookKey() {
    String k = widget.item?.uniqueKey ?? 'default';
    return k.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  }

  /// Stable identifier for the currently-attached secondary (translation)
  /// book, derived from its URL. Keeping this per-secondary — rather than
  /// per-primary — lets the user reuse the same translation book across
  /// multiple primary books without settings bleeding between them.
  /// Returns a fallback if no secondary is attached yet; callers should
  /// only read real settings when `_hasSecondary` is true.
  String _safeSecondaryBookKey() {
    String k = _secondaryUrl ?? 'secondary_default';
    return 'sec_${k.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  }

  Future<void> _initGestureVolume() async {
    try {
      final result = await _volumeChannel.invokeMethod('getVolume');
      if (result is List) {
        _gestureVolume = (result[0] as num).toDouble();
        _gestureMaxVolume = (result[1] as num).toDouble();
      }
    } catch (_) {}
  }

  Future<void> _initGestureFontSize() async {
    try {
      final raw = await _controller.evaluateJavascript(
          source: 'window.localStorage.getItem("fontSize") || "20"');
      String cleaned = raw.toString().replaceAll('"', '');
      _gestureFontSize = double.tryParse(cleaned) ?? 20;
    } catch (_) {}
  }

  /// Read the secondary controller's current font size from its
  /// localStorage. Both controllers technically share the same origin
  /// so the `fontSize` key is shared — but this still gives us an
  /// accurate starting point for the swipe gesture.
  Future<void> _initGestureFontSizeSecondary() async {
    try {
      if (_secondaryController == null) return;
      final raw = await _secondaryController!.evaluateJavascript(
          source: 'window.localStorage.getItem("fontSize") || "20"');
      String cleaned = raw.toString().replaceAll('"', '');
      _gestureFontSizeSecondary = double.tryParse(cleaned) ?? 20;
    } catch (_) {}
  }

  void _onEdgeVerticalDragUpdate(
      DragUpdateDetails d, bool isRight, bool isSecondary) {
    double delta = -d.delta.dy;
    if (isRight) {
      // Volume: map drag to volume steps. Global — not per book.
      double step = delta / 8;
      _gestureVolume = (_gestureVolume + step).clamp(0, _gestureMaxVolume);
      _volumeChannel.invokeMethod(
          'setVolume', {'level': _gestureVolume.round()});
      setState(() => _showVolumeIndicator = true);
    } else {
      // Font size: route to the controller for the half being swiped.
      final InAppWebViewController? target =
          isSecondary ? _secondaryController : _controller;
      if (target == null) return;
      double step = delta / 12;
      if (isSecondary) {
        _gestureFontSizeSecondary =
            (_gestureFontSizeSecondary + step).clamp(8, 60);
      } else {
        _gestureFontSize = (_gestureFontSize + step).clamp(8, 60);
      }
      final int px =
          (isSecondary ? _gestureFontSizeSecondary : _gestureFontSize)
              .round();
      target.evaluateJavascript(
          source: 'window.localStorage.setItem("fontSize", "$px")');
      target.evaluateJavascript(
          source:
              'document.querySelector(".book-content").style.fontSize = "${px}px"');
      setState(() {
        _showFontSizeIndicator = true;
        _lastFontSwipeWasSecondary = isSecondary;
      });
    }
  }

  void _onEdgeVerticalDragEnd(bool isRight) {
    if (isRight) {
      Future.delayed(const Duration(milliseconds: 600),
          () { if (mounted) setState(() => _showVolumeIndicator = false); });
    } else {
      Future.delayed(const Duration(milliseconds: 600),
          () { if (mounted) setState(() => _showFontSizeIndicator = false); });
    }
  }

  Widget _buildEdgeGestures(Widget child) {
    final double fontStripWidth =
        MediaQuery.of(context).size.width * 0.15;

    // Left edge handles font size. In split-screen mode we split the
    // strip vertically at `_splitRatio` so each half controls its own
    // book's font size.
    Widget leftEdge;
    if (_secondaryShown) {
      leftEdge = Column(
        children: [
          Expanded(
            flex: (_splitRatio * 100).round(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (d) =>
                  _onEdgeVerticalDragUpdate(d, false, false),
              onVerticalDragEnd: (_) => _onEdgeVerticalDragEnd(false),
            ),
          ),
          Expanded(
            flex: 100 - (_splitRatio * 100).round(),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragUpdate: (d) =>
                  _onEdgeVerticalDragUpdate(d, false, true),
              onVerticalDragEnd: (_) => _onEdgeVerticalDragEnd(false),
            ),
          ),
        ],
      );
    } else {
      leftEdge = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragUpdate: (d) =>
            _onEdgeVerticalDragUpdate(d, false, false),
        onVerticalDragEnd: (_) => _onEdgeVerticalDragEnd(false),
      );
    }

    return Stack(
      children: [
        child,
        // Left edge — font size (per half when split).
        Positioned(
          left: 0, top: 0, bottom: 0,
          width: fontStripWidth,
          child: leftEdge,
        ),
        // Right edge — volume. Global, full-height regardless of split.
        Positioned(
          right: 0, top: 0, bottom: 0,
          width: MediaQuery.of(context).size.width * 0.15,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragUpdate: (d) =>
                _onEdgeVerticalDragUpdate(d, true, false),
            onVerticalDragEnd: (_) => _onEdgeVerticalDragEnd(true),
          ),
        ),
        // Volume indicator
        if (_showVolumeIndicator)
          Positioned(
            right: 20, top: 0, bottom: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.volume_up,
                        color: Color(0xFFFFFF00), size: 28),
                    const SizedBox(height: 4),
                    Text(
                      '${(_gestureVolume / _gestureMaxVolume * 100).round()}%',
                      style: const TextStyle(
                          color: Color(0xFFFFFF00), fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Font size indicator
        if (_showFontSizeIndicator)
          Positioned(
            left: 20, top: 0, bottom: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.format_size,
                        color: Color(0xFFFFFF00), size: 28),
                    const SizedBox(height: 4),
                    Text(
                      '${(_lastFontSwipeWasSecondary ? _gestureFontSizeSecondary : _gestureFontSize).round()}px',
                      style: const TextStyle(
                          color: Color(0xFFFFFF00), fontSize: 14),
                    ),
                    if (_secondaryShown) ...[
                      const SizedBox(height: 2),
                      Text(
                        _lastFontSwipeWasSecondary ? 'translation' : 'primary',
                        style: const TextStyle(
                            color: Color(0xFFFFFF00), fontSize: 10),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      FocusScope.of(context).unfocus();
      _focusNode.requestFocus();
    }
  }

  @override
  void onSearch(String searchTerm, {String? sentence = ''}) async {
    _isRecursiveSearching = true;
    // Previously toggled SystemUiMode to edgeToEdge here and back to
    // immersiveSticky afterwards — ostensibly to unblock the
    // dictionary's FloatingSearchBar from the system nav bar. The
    // round-trip caused a visible reflow on the reader when the
    // dictionary popped back: the mode change fires an async
    // platform-channel call that updates window insets, which
    // triggers MediaQuery to rebuild, which reflows the WebView.
    // On screen this looked like the book scrolling two lines
    // further in for a frame and then snapping back to the original
    // position. The dictionary's search bar renders fine with the
    // system nav present, so the toggle is just unnecessary churn.
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
    _isRecursiveSearching = false;

    _focusNode.requestFocus();
  }

  @override
  void onCreatorClose() {
    _focusNode.unfocus();
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    Orientation orientation = MediaQuery.of(context).orientation;
    if (orientation != lastOrientation) {
      if (_controllerInitialised) {
        clearDictionaryResult();
      }
      lastOrientation = orientation;
    }

    return Focus(
      autofocus: true,
      focusNode: _focusNode,
      onFocusChange: (value) {
        if (mediaSource.volumePageTurningEnabled &&
            !(ModalRoute.of(context)?.isCurrent ?? false) &&
            !appModel.isCreatorOpen &&
            !_isRecursiveSearching) {
          _focusNode.requestFocus();
        }
      },
      canRequestFocus: true,
      onKey: (data, event) {
        if (ModalRoute.of(context)?.isCurrent ?? false) {
          if (mediaSource.volumePageTurningEnabled) {
            if (isDictionaryShown) {
              clearDictionaryResult();
              unselectWebViewTextSelection(_controller);
              mediaSource.clearCurrentSentence();

              return KeyEventResult.handled;
            }

            if (event.isKeyPressed(LogicalKeyboardKey.audioVolumeUp)) {
              unselectWebViewTextSelection(_controller);
              _controller.evaluateJavascript(source: leftArrowSimulateJs);

              return KeyEventResult.handled;
            }
            if (event.isKeyPressed(LogicalKeyboardKey.audioVolumeDown)) {
              unselectWebViewTextSelection(_controller);
              _controller.evaluateJavascript(source: rightArrowSimulateJs);

              return KeyEventResult.handled;
            }
          }

          return KeyEventResult.ignored;
        } else {
          return KeyEventResult.ignored;
        }
      },
      child: WillPopScope(
        onWillPop: onWillPop,
        child: Scaffold(
          backgroundColor: Colors.black,
          resizeToAvoidBottomInset: false,
          body: SafeArea(
            top: !mediaSource.extendPageBeyondNavigationBar,
            bottom: false,
            child: Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: <Widget>[
                buildBody(),
                buildDictionary(),
              ],
            ),
          ),
          bottomNavigationBar: ReaderAudioToolbar(
            bookKey: widget.item?.uniqueKey ?? 'default',
            secondaryBookKey:
                _hasSecondary ? _safeSecondaryBookKey() : null,
            appModel: appModel,
            secondaryShown: _secondaryShown,
            hasSecondary: _hasSecondary,
            secondaryTitle: _secondaryTitle,
            onToggleSecondary: _toggleSecondary,
            onOpenSecondaryManager: _openSecondaryManager,
            onRemoveSecondary: _removeSecondary,
            onSettingsChanged: _applyReaderSettings,
          ),
        ),
      ),
    );
  }

  Widget buildBody() {
    AsyncValue<LocalAssetsServer> server =
        ref.watch(ttuServerProvider(appModel.targetLanguage));

    return server.when(
      data: (srv) => _buildEdgeGestures(_buildSplitView(srv)),
      loading: buildLoading,
      error: (error, stack) => buildError(
        error: error,
        stack: stack,
        refresh: () {
          ref.invalidate(ttuServerProvider(appModel.targetLanguage));
        },
      ),
    );
  }

  Widget _buildSplitView(LocalAssetsServer server) {
    if (!_secondaryShown) {
      return buildReaderArea(server);
    }
    int topFlex = (_splitRatio * 100).round();
    int bottomFlex = 100 - topFlex;
    return Column(
      children: [
        Expanded(flex: topFlex, child: buildReaderArea(server)),
        _buildDivider(),
        Expanded(flex: bottomFlex, child: _buildSecondaryReader(server)),
      ],
    );
  }

  Widget _buildDivider() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (details) {
        final box = context.findRenderObject() as RenderBox;
        final totalHeight = box.size.height;
        setState(() {
          _splitRatio = (_splitRatio + details.delta.dy / totalHeight)
              .clamp(0.2, 0.8);
        });
      },
      onVerticalDragEnd: (_) {
        String key = _safeBookKey();
        _readerBox.put('split_ratio_$key', _splitRatio);
      },
      child: Container(
        height: 8,
        color: Theme.of(context).cardColor,
        child: Center(
          child: Container(
            width: 40,
            height: 3,
            decoration: BoxDecoration(
              color: Theme.of(context).unselectedWidgetColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSecondaryReader(LocalAssetsServer server) {
    String url = _secondaryUrl ??
        'http://localhost:${server.boundPort}/manage.html';
    return InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        mediaPlaybackRequiresUserGesture: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        javaScriptCanOpenWindowsAutomatically: true,
        verticalScrollbarThumbColor: Colors.transparent,
        verticalScrollbarTrackColor: Colors.transparent,
        horizontalScrollbarThumbColor: Colors.transparent,
        horizontalScrollbarTrackColor: Colors.transparent,
        scrollbarFadingEnabled: false,
        appCachePath: appModel.browserDirectory.path,
        cacheMode: cacheMode,
        supportMultipleWindows: true,
        disableContextMenu: true,
      ),
      onWebViewCreated: (controller) {
        _secondaryController = controller;
      },
      onLoadStop: (controller, uri) async {
        await controller.evaluateJavascript(
            source: 'window.localStorage.setItem("autoBookmark", "1")');
        await _injectUiTheme(controller);
        await _injectIdbPatch(controller);
        await _injectTtfAutofill(controller);
        await _injectUserFonts(controller);
        _applyReaderSettings();
        _initGestureFontSizeSecondary();
      },
      onTitleChanged: (controller, title) async {
        await _injectUiTheme(controller);
        await _injectIdbPatch(controller);
        await _injectTtfAutofill(controller);
        await _injectUserFonts(controller);
        _applyReaderSettings();
        WebUri? uri = await controller.getUrl();
        if (uri == null) return;
        String rawUrl = uri.toString();
        // SPA navigates to /b?id=X — convert to /b.html?id=X for direct load
        String saveUrl = rawUrl.replaceFirst('/b?id=', '/b.html?id=');
        if (!saveUrl.contains('/b.html?id=')) return;
        // Save URL if new
        if (saveUrl != _secondaryUrl) {
          _secondaryUrl = saveUrl;
          _hasSecondary = true;
          String key = _safeBookKey();
          await _readerBox.put('secondary_url_$key', saveUrl);
        }
        // Format title as "MainBook ⇨ SecondaryBook"
        if (title != null && title.isNotEmpty) {
          String bookName = title.split(' | ').first;
          if (bookName.isNotEmpty && bookName != 'ッツ Ebook Reader') {
            // If already renamed (contains ⇨), extract the translation part
            if (bookName.contains('⇨')) {
              bookName = bookName.split('⇨').last.trim();
            }
            String mainTitle = widget.item?.title ?? '';
            String formattedTitle = mainTitle.isNotEmpty
                ? '$mainTitle ⇨ $bookName'
                : bookName;
            // Only rename if not already renamed
            if (_secondaryTitle != formattedTitle) {
              _secondaryTitle = formattedTitle;
              String key = _safeBookKey();
              await _readerBox.put('secondary_title_$key', formattedTitle);
              // Rename in ッツ reader's IndexedDB
              String jsBookName = bookName
                  .replaceAll('\\', '\\\\')
                  .replaceAll("'", "\\'");
              String jsNewTitle = formattedTitle
                  .replaceAll('\\', '\\\\')
                  .replaceAll("'", "\\'");
              await controller.evaluateJavascript(source: '''
                (async function() {
                  try {
                    var req = indexedDB.open('books');
                    req.onsuccess = function() {
                      var db = req.result;
                      var tx = db.transaction('data', 'readwrite');
                      var store = tx.objectStore('data');
                      var idx = store.index('title');
                      var get = idx.get('$jsBookName');
                      get.onsuccess = function() {
                        var book = get.result;
                        if (book && !book.title.includes('⇨')) {
                          book.title = '$jsNewTitle';
                          book.lastBookOpen = 0;
                          store.put(book);
                        }
                      };
                    };
                  } catch(e) {}
                })();
              ''');
            }
          }
        }
        if (mounted) setState(() {});
      },
    );
  }

  void _toggleSecondary() {
    setState(() {
      _secondaryShown = !_secondaryShown;
    });
  }

  void _openSecondaryManager() {
    _secondaryUrl = null;
    _secondaryTitle = null;
    setState(() {
      _secondaryShown = true;
    });
  }

  void _removeSecondary() {
    String key = _safeBookKey();
    _readerBox.delete('secondary_url_$key');
    _readerBox.delete('secondary_title_$key');
    _readerBox.delete('split_ratio_$key');
    _secondaryUrl = null;
    _secondaryTitle = null;
    _hasSecondary = false;
    _secondaryShown = false;
    _secondaryController = null;
    setState(() {});
  }

  /// Apply per-book reader appearance settings via CSS injection.
  ///
  /// Primary and secondary (translation) books each have their own stored
  /// settings keyed by their respective unique keys. Each controller only
  /// receives its book's settings so they can be configured independently.
  void _applyReaderSettings() async {
    // Primary
    String primaryKey = _safeBookKey();
    ReaderAppearanceSettings primarySettings =
        ReaderAppearanceSettings.load(_readerBox, primaryKey);
    String primaryCss = primarySettings.toCss().replaceAll('\n', ' ');
    String primaryJs = _buildAppearanceInjectJs(primaryCss);
    // Re-inject the user-fonts stylesheet before the appearance CSS
    // so newly imported fonts (added via the settings dialog we just
    // returned from) are actually registered by the time the reader
    // styles reference them. Without this round-trip, the user would
    // have to reload the book before the new font took effect.
    await _injectUserFonts(_controller);
    await _controller.evaluateJavascript(source: primaryJs);

    // Secondary (translation book) — load its own settings.
    if (_secondaryController != null && _hasSecondary) {
      String secondaryKey = _safeSecondaryBookKey();
      ReaderAppearanceSettings secondarySettings =
          ReaderAppearanceSettings.load(_readerBox, secondaryKey);
      String secondaryCss = secondarySettings.toCss().replaceAll('\n', ' ');
      String secondaryJs = _buildAppearanceInjectJs(secondaryCss);
      await _injectUserFonts(_secondaryController!);
      await _secondaryController!.evaluateJavascript(source: secondaryJs);
    }
  }

  String _buildAppearanceInjectJs(String css) {
    return '''
      (function() {
        var el = document.getElementById('reader-appearance');
        if (el) el.remove();
        var s = document.createElement('style');
        s.id = 'reader-appearance';
        s.textContent = ${_escapeJsString(css)};
        document.head.appendChild(s);
      })();
    ''';
  }

  /// CSS to restyle the ッツ reader UI as yellow-on-black.
  static const String _uiThemeCss = '''
    body, html { background-color: #000 !important; color: #FFFF00 !important; }
    /* TTU defines `--background-color` (#eceff1) and `--font-color`
       (rgba(0,0,0,.87)) at :root and uses them via Tailwind's
       `bg-background-color` etc. on inner controls (inputs, some
       buttons). Retheme the defaults so those controls pick up our
       colors automatically — no !important, so TTU's runtime theme
       switcher can still override for book content when the user
       picks a reader theme. */
    :root {
      --background-color: #111;
      --font-color: #FFFF00;
    }
    /* Explicit override for the Tailwind utility in case stylesheet
       order or specificity prevents the var change above from
       flowing through. */
    .bg-background-color { background-color: #111 !important; }
    * { border-color: #333 !important; }
    button, select, input, textarea {
      background-color: #111 !important;
      color: #FFFF00 !important;
      border-color: #555 !important;
    }
    /* Exempt TTU's invisible top tap-target (a 32 px-tall full-width
       <button> sibling of the toolbar wrapper that toggles toolbar
       visibility). The generic button rule above would otherwise
       paint it solid #111, rendering as a dark strip that covers
       the first line of text when the toolbar itself is hidden. */
    button.fixed.inset-x-0.top-0.z-10.h-8.w-full {
      background-color: transparent !important;
      border: none !important;
    }
    a { color: #FFFF00 !important; }
    .bg-gray-700, .bg-gray-800, .bg-gray-900,
    [class*="bg-gray"] { background-color: #111 !important; color: #FFFF00 !important; }
    /* TTU's font-picker dialog (and a few other modals) uses Tailwind's
       `.bg-white` for the dialog container, plus `.hover:bg-white` /
       `.hover:text-gray-700` on menu items inside it. Without these
       overrides, the font-add popup opens white-on-yellow — unreadable
       against the rest of the app's yellow-on-black theme. */
    .bg-white, [class*="bg-white"] {
      background-color: #111 !important;
      color: #FFFF00 !important;
    }
    .hover\\:bg-white:hover, [class*="hover:bg-white"]:hover {
      background-color: #222 !important;
      color: #FFFF00 !important;
    }
    .hover\\:text-gray-700:hover, [class*="hover:text-gray"]:hover {
      color: #FFFF00 !important;
    }
    .text-gray-700 { color: #FFFF00 !important; }
    /* Native file-picker "Browse" button (rendered by WebKit) —
       white by default, needs forcing to match. Appears in TTU's
       font-add dialog next to the font-name input. */
    input[type="file"]::-webkit-file-upload-button {
      background-color: #111 !important;
      color: #FFFF00 !important;
      border: 1px solid #555 !important;
    }
    /* TTU wraps the file-upload row in a `border border-black`
       container — black on black would read as a solid block. */
    .border-black { border-color: #555 !important; }
    .text-gray-500, .text-gray-400, .text-gray-300,
    [class*="text-gray"] { color: #FFFF00 !important; }
    /* TTU's button base class (`Dn` in the compiled bundle) uses
       `text-cyan-900` (#164e63) — unreadable on our #111 bg. */
    .text-cyan-900 { color: #FFFF00 !important; }
    .border-b-gray-200, [class*="border"] { border-color: #333 !important; }
    svg { fill: #FFFF00 !important; color: #FFFF00 !important; }
    .elevation-4 { background-color: #111 !important; }
    dialog, [role="dialog"] { background-color: #111 !important; color: #FFFF00 !important; }
    ::-webkit-scrollbar { background: #000 !important; }
    ::-webkit-scrollbar-thumb { background: #555 !important; }
  ''';

  /// Inject the yellow-on-black UI theme CSS.
  Future<void> _injectUiTheme(InAppWebViewController controller) async {
    String css = _uiThemeCss.replaceAll('\n', ' ');
    String js = '''
      (function() {
        var el = document.getElementById('ttu-ui-theme');
        if (el) el.remove();
        var s = document.createElement('style');
        s.id = 'ttu-ui-theme';
        s.textContent = ${_escapeJsString(css)};
        document.head.appendChild(s);
      })();
    ''';
    await controller.evaluateJavascript(source: js);
  }

  static String _escapeJsString(String s) {
    return "'${s.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'";
  }

  /// Monkey-patch IndexedDB.put to force lastBookOpen=0 for translation books.
  static const String _idbPatchJs = '''
    (function() {
      if (window.__ttuPatchApplied) return;
      window.__ttuPatchApplied = true;
      var origPut = IDBObjectStore.prototype.put;
      IDBObjectStore.prototype.put = function(value) {
        if (value && value.title && typeof value.title === 'string'
            && value.title.includes('⇨')) {
          value.lastBookOpen = 0;
        }
        return origPut.apply(this, arguments);
      };
    })();
  ''';

  /// Inject the IndexedDB patch into a WebView controller.
  Future<void> _injectIdbPatch(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: _idbPatchJs);
  }

  /// JavaScript to auto-fill TTU's font-add dialog's Font Name input
  /// from the TTF/OTF file the user picks. TTU's default workflow
  /// requires the user to also type the font family name themselves
  /// before the Add button enables — tedious, and they usually end
  /// up typing whatever the file already declares internally. This
  /// hook reads the file's embedded `name` table (OpenType spec) and
  /// pre-fills the field when it's still blank, then dispatches an
  /// `input` event so Svelte's bound state in the dialog updates and
  /// the Add button enables.
  ///
  /// Only handles TTF/OTF (uncompressed OpenType). WOFF and WOFF2 are
  /// compressed — parsing them here would require a Brotli decoder,
  /// not worth the weight for what's realistically rare (most font
  /// files users download are TTF or OTF). For WOFF/WOFF2 the user
  /// still has to type the name by hand.
  static const String _ttfAutofillJs = r'''
    (function() {
      if (window.__ttuFontAutofillApplied) return;
      window.__ttuFontAutofillApplied = true;

      // Parse an OpenType `name` table out of a raw TTF/OTF buffer
      // and return the best available family-name string, or null if
      // we can't recognise the file. Prefers, in order:
      //   - nameID 16 (Typographic Family Name) — the modern one
      //   - nameID  1 (Font Family Name)        — legacy fallback
      //   - nameID  4 (Full Font Name)          — last resort
      function parseFontName(buffer) {
        try {
          var view = new DataView(buffer);
          var numTables = view.getUint16(4);
          if (numTables < 1 || numTables > 100) return null;
          // Walk the table directory for the 'name' tag.
          var nameOffset = -1;
          for (var i = 0; i < numTables; i++) {
            var rec = 12 + i * 16;
            var tag = String.fromCharCode(
              view.getUint8(rec),
              view.getUint8(rec + 1),
              view.getUint8(rec + 2),
              view.getUint8(rec + 3)
            );
            if (tag === 'name') {
              nameOffset = view.getUint32(rec + 8);
              break;
            }
          }
          if (nameOffset < 0) return null;
          var count = view.getUint16(nameOffset + 2);
          var stringOffset = view.getUint16(nameOffset + 4);
          var stringsStart = nameOffset + stringOffset;
          var cands = { 16: null, 1: null, 4: null };
          for (var j = 0; j < count; j++) {
            var off = nameOffset + 6 + j * 12;
            var platformID = view.getUint16(off);
            var encodingID = view.getUint16(off + 2);
            var nameID = view.getUint16(off + 6);
            var length = view.getUint16(off + 8);
            var strOff = view.getUint16(off + 10);
            if (!(nameID in cands)) continue;
            if (cands[nameID]) continue;
            var strStart = stringsStart + strOff;
            var value = null;
            if (platformID === 3 &&
                (encodingID === 0 || encodingID === 1)) {
              // Windows UCS-2 BE
              var s = '';
              for (var k = 0; k < length; k += 2) {
                s += String.fromCharCode(view.getUint16(strStart + k));
              }
              value = s;
            } else if (platformID === 0) {
              // Unicode platform — also UCS-2 BE
              var s2 = '';
              for (var k2 = 0; k2 < length; k2 += 2) {
                s2 += String.fromCharCode(view.getUint16(strStart + k2));
              }
              value = s2;
            } else if (platformID === 1 && encodingID === 0) {
              // Mac Roman — approximate with Latin-1 for our purposes.
              var s3 = '';
              for (var k3 = 0; k3 < length; k3++) {
                s3 += String.fromCharCode(view.getUint8(strStart + k3));
              }
              value = s3;
            }
            if (value) cands[nameID] = value;
          }
          return cands[16] || cands[1] || cands[4] || null;
        } catch (e) {
          return null;
        }
      }

      // Find the companion "Font Name" text input for a given file
      // input. TTU's add-font dialog groups them inside a nearby
      // ancestor, so walk up until we find an <input type=text> that
      // is actually visible.
      function findNameInput(fileInput) {
        var container = fileInput.parentElement;
        while (container && container !== document.body) {
          var candidates = container.querySelectorAll(
            'input[type="text"]'
          );
          for (var i = 0; i < candidates.length; i++) {
            var el = candidates[i];
            // offsetParent is null for hidden elements — skip those.
            if (el.offsetParent !== null) return el;
          }
          container = container.parentElement;
        }
        return null;
      }

      // Event delegation at the document level so this keeps working
      // after Svelte re-renders and swaps DOM nodes.
      document.addEventListener('change', function(ev) {
        var target = ev.target;
        if (!(target instanceof HTMLInputElement)) return;
        if (target.type !== 'file') return;
        var file = target.files && target.files[0];
        if (!file) return;
        var nameLower = file.name.toLowerCase();
        if (!nameLower.endsWith('.ttf') && !nameLower.endsWith('.otf')) {
          return;
        }
        var nameInput = findNameInput(target);
        if (!nameInput) return;
        // Don't trample user input — only fill if still blank.
        if (nameInput.value && nameInput.value.trim().length > 0) return;
        var reader = new FileReader();
        reader.onload = function() {
          var extracted = parseFontName(reader.result);
          if (!extracted) return;
          var cleaned = extracted.trim();
          if (!cleaned) return;
          nameInput.value = cleaned;
          // Svelte's `bind:value` listens for `input`, not `change`.
          nameInput.dispatchEvent(new Event('input', { bubbles: true }));
        };
        reader.readAsArrayBuffer(file);
      }, false);
    })();
  ''';

  /// Inject the TTF/OTF auto-fill hook into a WebView controller.
  Future<void> _injectTtfAutofill(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: _ttfAutofillJs);
  }

  /// Build a tiny `<style id="user-fonts">` stylesheet of `@font-face`
  /// rules that reference the user's imported fonts by URL on the
  /// loopback HTTP server [UserFontsStore] runs. This mirrors the way
  /// TTU itself serves imported fonts (cache API + service worker at
  /// `/userfonts/*`) — a regular cross-origin HTTP fetch that the
  /// browser can load asynchronously, without the evaluateJavascript
  /// payload-size and memory-pressure hazards of a multi-MB base64
  /// data URL.
  ///
  /// Returns the empty string if the server hasn't started yet or no
  /// fonts are registered, in which case the caller clears the style
  /// element to avoid leaving stale `@font-face` rules behind.
  Future<String> _userFontsFaceCss() async {
    try {
      await UserFontsStore.instance.initialise();
    } catch (_) {
      return '';
    }
    final port = UserFontsStore.instance.port;
    if (port == null) return '';
    final entries = UserFontsStore.instance.list();
    if (entries.isEmpty) return '';

    final buf = StringBuffer();
    for (final entry in entries) {
      final ext = entry.fileName.split('.').last.toLowerCase();
      // CSS format hint — must be one of the spec's known values
      // (`truetype`, `opentype`, `woff`, `woff2`, ...). Unknown hints
      // cause Chromium to drop the source.
      final formatHint = ext == 'otf' ? 'opentype' : 'truetype';
      // Percent-encode the path component so exotic filenames (spaces,
      // Unicode) survive the URL round-trip.
      final encodedFileName = Uri.encodeComponent(entry.fileName);
      // Escape the font family name for CSS double-quoted string.
      final cssName = entry.name.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      buf.write(
        '@font-face { font-family: "$cssName"; '
        'src: url("http://127.0.0.1:$port/$encodedFileName") '
        'format("$formatHint"); '
        'font-display: swap; } ',
      );
    }
    return buf.toString();
  }

  /// Read-and-inject of the user-fonts stylesheet. Idempotent —
  /// replaces any existing `#user-fonts` style element so re-injecting
  /// after an import or removal doesn't stack rules.
  Future<void> _injectUserFonts(InAppWebViewController controller) async {
    final css = await _userFontsFaceCss();
    if (css.isEmpty) {
      // Still clear any prior injection so a removed font doesn't
      // linger after its entry was deleted.
      await controller.evaluateJavascript(source: '''
        (function() {
          var el = document.getElementById('user-fonts');
          if (el) el.remove();
        })();
      ''');
      return;
    }
    final js = '''
      (function() {
        var el = document.getElementById('user-fonts');
        if (el) el.remove();
        var s = document.createElement('style');
        s.id = 'user-fonts';
        s.textContent = ${_escapeJsString(css)};
        document.head.appendChild(s);
      })();
    ''';
    await controller.evaluateJavascript(source: js);
  }


  void setDictionaryColors() async {
    String currentTheme = (await _controller.evaluateJavascript(
            source: 'window.localStorage.getItem("theme")'))
        .toString();
    switch (currentTheme) {
      case 'light-theme':
        appModel.setOverrideDictionaryTheme(appModel.theme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(249, 249, 249, dictionaryEntryOpacity),
        );
        break;
      case 'ecru-theme':
        appModel.setOverrideDictionaryTheme(appModel.theme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(247, 246, 235, dictionaryEntryOpacity),
        );
        break;
      case 'water-theme':
        appModel.setOverrideDictionaryTheme(appModel.theme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(223, 236, 244, dictionaryEntryOpacity),
        );
        break;
      case 'gray-theme':
        appModel.setOverrideDictionaryTheme(appModel.darkTheme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(35, 39, 42, dictionaryEntryOpacity),
        );
        break;
      case 'dark-theme':
        appModel.setOverrideDictionaryTheme(appModel.darkTheme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(18, 18, 18, dictionaryEntryOpacity),
        );
        break;
      case 'black-theme':
        appModel.setOverrideDictionaryTheme(appModel.darkTheme);
        appModel.setOverrideDictionaryColor(
          Color.fromRGBO(16, 16, 16, dictionaryEntryOpacity),
        );
        break;
    }

    if (mounted) {
      clearDictionaryResult();
      setState(() {});
    }
  }

  String sanitizeWebViewTextSelection(String? text) {
    if (text == null) {
      return '';
    }

    text = text.replaceAll('\\n', '\n');
    text = text.trim();
    return text;
  }

  Future<String> getWebViewTextSelection(
      InAppWebViewController webViewController) async {
    String? selectedText = await webViewController.getSelectedText();
    selectedText = sanitizeWebViewTextSelection(selectedText);
    return selectedText;
  }

  CacheMode get cacheMode {
    if (mediaSource.currentTtuInternalVersion ==
        ReaderTtuSource.ttuInternalVersion) {
      return CacheMode.LOAD_CACHE_ELSE_NETWORK;
    } else {
      mediaSource.setTtuInternalVersion();
      return CacheMode.LOAD_NO_CACHE;
    }
  }

  createFileFromBase64(String base64Content) async {
    var bytes = base64Decode(base64Content.replaceAll('\n', ''));
    DocumentFileSavePlus().saveFile(
      bytes.buffer.asUint8List(),
      _suggestedFilename,
      _mimeType,
    );
    Fluttertoast.showToast(msg: t.file_downloaded(name: _suggestedFilename));
  }

  Widget buildReaderArea(LocalAssetsServer server) {
    return InAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri(
          widget.item?.mediaIdentifier ??
              'http://localhost:${server.boundPort}/manage.html',
        ),
      ),
      onPermissionRequest: (controller, origin) async {
        return PermissionResponse(
          action: PermissionResponseAction.GRANT,
        );
      },
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        mediaPlaybackRequiresUserGesture: false,
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        javaScriptCanOpenWindowsAutomatically: true,
        useOnDownloadStart: true,
        verticalScrollbarThumbColor: Colors.transparent,
        verticalScrollbarTrackColor: Colors.transparent,
        horizontalScrollbarThumbColor: Colors.transparent,
        horizontalScrollbarTrackColor: Colors.transparent,
        scrollbarFadingEnabled: false,
        appCachePath: appModel.browserDirectory.path,
        cacheMode: cacheMode,
        supportMultipleWindows: true,
      ),
      contextMenu: contextMenu,
      onConsoleMessage: onConsoleMessage,
      onWebViewCreated: (controller) {
        _controller = controller;
        _controllerInitialised = true;

        controller.addJavaScriptHandler(
          handlerName: 'blobToBase64Handler',
          callback: (data) async {
            if (data.isNotEmpty) {
              final String base64Content = data[0];
              createFileFromBase64(base64Content);
            }
          },
        );
      },
      onCreateWindow: (controller, createWindowRequest) async {
        showDialog(
          context: context,
          builder: (context) {
            return AlertDialog(
              insetPadding: Spacing.of(context).insets.all.big,
              contentPadding: EdgeInsets.zero,
              content: SizedBox(
                width: MediaQuery.of(context).size.width,
                height: MediaQuery.of(context).size.height * (3 / 4),
                child: InAppWebView(
                  initialSettings: InAppWebViewSettings(
                    supportZoom: false,
                    disableContextMenu: true,
                    allowFileAccessFromFileURLs: true,
                    allowUniversalAccessFromFileURLs: true,
                    mediaPlaybackRequiresUserGesture: false,
                    verticalScrollBarEnabled: false,
                    horizontalScrollBarEnabled: false,
                    javaScriptCanOpenWindowsAutomatically: true,
                    userAgent: 'random',
                    useOnDownloadStart: true,
                    verticalScrollbarThumbColor: Colors.transparent,
                    verticalScrollbarTrackColor: Colors.transparent,
                    horizontalScrollbarThumbColor: Colors.transparent,
                    horizontalScrollbarTrackColor: Colors.transparent,
                    scrollbarFadingEnabled: false,
                    appCachePath: appModel.browserDirectory.path,
                    cacheMode: cacheMode,
                    supportMultipleWindows: true,
                  ),
                  windowId: createWindowRequest.windowId,
                  onDownloadStartRequest: onDownloadStartRequest,
                  onCloseWindow: (controller) {
                    if (mounted) {
                      Navigator.pop(context);
                    }
                  },
                ),
              ),
            );
          },
        );
        return true;
      },
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.PROCEED,
        );
      },
      onLoadStop: (controller, uri) async {
        if (mediaSource.adaptTtuTheme) {
          setDictionaryColors();
        }

        await controller.evaluateJavascript(source: javascriptToExecute);
        await controller.evaluateJavascript(
            source:
                'window.localStorage.setItem("autoBookmark", "1")');
        await _injectUiTheme(controller);
        await _injectIdbPatch(controller);
        await _injectTtfAutofill(controller);
        await _injectUserFonts(controller);
        _applyReaderSettings();
        _initGestureFontSize();
        Future.delayed(const Duration(seconds: 1), _focusNode.requestFocus);
      },
      onTitleChanged: (controller, title) async {
        await controller.evaluateJavascript(source: javascriptToExecute);

        if (mediaSource.adaptTtuTheme) {
          setDictionaryColors();
        }
        await _injectUiTheme(controller);
        await _injectIdbPatch(controller);
        await _injectTtfAutofill(controller);
        await _injectUserFonts(controller);
        _applyReaderSettings();
      },
      onDownloadStartRequest: onDownloadStartRequest,
    );
  }

  String _suggestedFilename = '';
  String _mimeType = '';

  void onDownloadStartRequest(
      InAppWebViewController controller, DownloadStartRequest request) async {
    _mimeType = request.mimeType ?? _mimeType;

    _suggestedFilename = request.suggestedFilename ?? _suggestedFilename;

    await controller.evaluateJavascript(
        source: downloadFileJs.replaceAll(
            'blobUrlPlaceholder', request.url.toString()));
  }

  Future<void> selectTextOnwards({
    required int cursorX,
    required int cursorY,
    required int offsetIndex,
    required int length,
    required int whitespaceOffset,
    required bool isSpaceDelimited,
  }) async {
    await _controller.setContextMenu(emptyContextMenu);
    await _controller.evaluateJavascript(
      source:
          'selectTextForTextLength($cursorX, $cursorY, $offsetIndex, $length, $whitespaceOffset, $isSpaceDelimited);',
    );
    await _controller.setContextMenu(contextMenu);
  }

  void onConsoleMessage(
    InAppWebViewController controller,
    ConsoleMessage message,
  ) async {
    DateTime now = DateTime.now();
    if (lastMessageTime != null &&
        now.difference(lastMessageTime!) < consoleMessageDebounce) {
      return;
    }

    lastMessageTime = now;

    late Map<String, dynamic> messageJson;
    try {
      messageJson = jsonDecode(message.message);
    } catch (e) {
      JsonEncoder encoder = const JsonEncoder.withIndent('  ');
      debugPrint(encoder.convert(message.toJson()));

      return;
    }

    switch (messageJson['jidoujisho-message-type']) {
      case 'lookup':
        FocusScope.of(context).unfocus();
        _focusNode.requestFocus();

        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

        int index = messageJson['index'];
        String text = messageJson['text'];
        int x = messageJson['x'];
        int y = messageJson['y'];

        late JidoujishoPopupPosition position;
        if (MediaQuery.of(context).orientation == Orientation.portrait) {
          if (y < MediaQuery.of(context).size.height / 2) {
            position = JidoujishoPopupPosition.bottomHalf;
          } else {
            position = JidoujishoPopupPosition.topHalf;
          }
        } else {
          if (x < MediaQuery.of(context).size.width / 2) {
            position = JidoujishoPopupPosition.rightHalf;
          } else {
            position = JidoujishoPopupPosition.leftHalf;
          }
        }

        text = text.replaceAll('\\n', '\n');

        if (text.isEmpty || index == -1) {
          clearDictionaryResult();
          mediaSource.clearCurrentSentence();
          return;
        }

        try {
          /// If we cut off at a lone surrogate, offset the index back by 1. The
          /// selection meant to select the index before
          RegExp loneSurrogate = RegExp(
            '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?:[^\uD800-\uDBFF]|^)[\uDC00-\uDFFF]',
          );
          if (index != 0 && text.substring(index).startsWith(loneSurrogate)) {
            index = index - 1;
          }

          bool isSpaceDelimited = appModel.targetLanguage.isSpaceDelimited;

          String searchTerm = appModel.targetLanguage.getSearchTermFromIndex(
            text: text,
            index: index,
          );
          int whitespaceOffset =
              searchTerm.length - searchTerm.trimLeft().length;

          int offsetIndex = appModel.targetLanguage
                  .getStartingIndex(text: text, index: index) +
              whitespaceOffset;

          int length = appModel.targetLanguage.getGuessHighlightLength(
            searchTerm: searchTerm,
          );

          if (mediaSource.highlightOnTap) {
            await selectTextOnwards(
              cursorX: x,
              cursorY: y,
              offsetIndex: offsetIndex,
              length: length,
              whitespaceOffset: whitespaceOffset,
              isSpaceDelimited: isSpaceDelimited,
            );
          }

          searchDictionaryResult(
            searchTerm: searchTerm,
            position: position,
          ).then((_) async {
            length = appModel.targetLanguage.getFinalHighlightLength(
              result: currentResult,
              searchTerm: searchTerm,
            );

            if (mediaSource.highlightOnTap) {
              await selectTextOnwards(
                cursorX: x,
                cursorY: y,
                offsetIndex: offsetIndex,
                length: length,
                whitespaceOffset: whitespaceOffset,
                isSpaceDelimited: isSpaceDelimited,
              );

              if (!dictionaryPopupShown) {
                unselectWebViewTextSelection(_controller);
              }
            }

            JidoujishoTextSelection selection =
                appModel.targetLanguage.getSentenceFromParagraph(
              paragraph: text,
              index: index,
              startOffset: offsetIndex,
              endOffset: offsetIndex + length,
            );

            mediaSource.setCurrentSentence(
              selection: selection,
            );
          });
        } catch (e) {
          clearDictionaryResult();
        }

        break;
    }
  }

  Future<void> unselectWebViewTextSelection(
      InAppWebViewController webViewController) async {
    String source = '''
if (!window.getSelection().isCollapsed) {
  window.getSelection().removeAllRanges();
}
''';
    await webViewController.evaluateJavascript(source: source);
  }

  /// Get the default context menu for sources that make use of embedded web
  /// views.
  ContextMenu get contextMenu => ContextMenu(
        settings: ContextMenuSettings(
          hideDefaultSystemContextMenuItems: true,
        ),
        menuItems: [
          searchMenuItem(),
          stashMenuItem(),
          copyMenuItem(),
          shareMenuItem(),
          creatorMenuItem(),
        ],
      );

  /// Get the default context menu for sources that make use of embedded web
  /// views.
  ContextMenu get emptyContextMenu => ContextMenu(
        settings: ContextMenuSettings(
          hideDefaultSystemContextMenuItems: true,
        ),
        menuItems: [],
      );

  ContextMenuItem searchMenuItem() {
    return ContextMenuItem(
      id: 1,
      title: t.search,
      action: searchMenuAction,
    );
  }

  ContextMenuItem stashMenuItem() {
    return ContextMenuItem(
      id: 2,
      title: t.stash,
      action: stashMenuAction,
    );
  }

  ContextMenuItem copyMenuItem() {
    return ContextMenuItem(
      id: 3,
      title: t.copy,
      action: copyMenuAction,
    );
  }

  ContextMenuItem shareMenuItem() {
    return ContextMenuItem(
      id: 4,
      title: t.share,
      action: shareMenuAction,
    );
  }

  ContextMenuItem creatorMenuItem() {
    return ContextMenuItem(
      id: 5,
      title: t.creator,
      action: creatorMenuAction,
    );
  }

  void searchMenuAction() async {
    String searchTerm = await getSelectedText();
    _isRecursiveSearching = true;

    await unselectWebViewTextSelection(_controller);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await Future.delayed(const Duration(milliseconds: 5), () {});
    await appModel.openRecursiveDictionarySearch(
      searchTerm: searchTerm,
      killOnPop: false,
    );
    await Future.delayed(const Duration(milliseconds: 5), () {});
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _isRecursiveSearching = false;
    _focusNode.requestFocus();
  }

  void stashMenuAction() async {
    String searchTerm = await getSelectedText();
    appModel.addToStash(terms: [searchTerm]);
    await unselectWebViewTextSelection(_controller);
  }

  void creatorMenuAction() async {
    String text = (await getSelectedText()).replaceAll('\\n', '\n');

    await unselectWebViewTextSelection(_controller);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await Future.delayed(const Duration(milliseconds: 5), () {});

    await appModel.openCreator(
      ref: ref,
      killOnPop: false,
      creatorFieldValues: CreatorFieldValues(
        textValues: {
          SentenceField.instance: text,
          TermField.instance: '',
          ClozeBeforeField.instance: '',
          ClozeInsideField.instance: '',
          ClozeAfterField.instance: '',
        },
      ),
    );

    await Future.delayed(const Duration(milliseconds: 5), () {});
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _focusNode.requestFocus();
  }

  void copyMenuAction() async {
    String searchTerm = await getSelectedText();
    Clipboard.setData(ClipboardData(text: searchTerm));
    await unselectWebViewTextSelection(_controller);
  }

  void shareMenuAction() async {
    String searchTerm = await getSelectedText();
    Share.share(searchTerm);
    await unselectWebViewTextSelection(_controller);
  }

  Future<String> getSelectedText() async {
    return (await _controller.getSelectedText() ?? '')
        .replaceAll('\\n', '\n')
        .trim();
  }

  String downloadFileJs = '''
var xhr = new XMLHttpRequest();
var blobUrl = "blobUrlPlaceholder";
console.log(blobUrl);
xhr.open('GET', blobUrl, true);
xhr.responseType = 'blob';
xhr.onload = function(e) {
  if (this.status == 200) {
    var blob = this.response;
    var reader = new FileReader();
    reader.readAsDataURL(blob);
    reader.onloadend = function() {
      var base64data = reader.result;
      var base64ContentArray = base64data.split(",")     ;
      var mimeType = base64ContentArray[0].match(/[^:\\s*]\\w+\\/[\\w-+\\d.]+(?=[;| ])/)[0];
      var decodedFile = base64ContentArray[1];
      console.log(mimeType);
      window.flutter_inappwebview.callHandler('blobToBase64Handler', decodedFile, mimeType);
    };
  };
};
xhr.send();
''';

  /// This is executed upon page load and change.
  /// More accurate readability courtesy of
  /// https://github.com/birchill/10ten-ja-reader/blob/fbbbde5c429f1467a7b5a938e9d67597d7bd5ffa/src/content/get-text.ts#L314
  String javascriptToExecute = """
/*jshint esversion: 6 */

function tapToSelect(e) {
  if (getSelectionText()) {
    console.log(JSON.stringify({
				"index": -1,
				"text": getSelectionText(),
				"jidoujisho-message-type": "lookup",
        "x": e.clientX,
        "y": e.clientY,
        "isCreator": "no",
			}));
  }

  var result = document.caretRangeFromPoint(e.clientX, e.clientY);

  if (e.target.classList.contains('book-content')) {
    console.log(JSON.stringify({
      "index": -1,
      "text": getSelectionText(),
      "jidoujisho-message-type": "lookup",
      "x": e.clientX,
      "y": e.clientY,
      "isCreator": "no",
    }));
    return;
  }

  var selectedElement = result.startContainer;
  var paragraph = result.startContainer;
  var offsetNode = result.startContainer;
  var offset = result.startOffset;

  var adjustIndex = false;

  if (!!offsetNode && offsetNode.nodeType === Node.TEXT_NODE && offset) {
      const range = new Range();
      range.setStart(offsetNode, offset - 1);
      range.setEnd(offsetNode, offset);

      const bbox = range.getBoundingClientRect();
      if (bbox.left <= e.x && bbox.right >= e.x &&
          bbox.top <= e.y && bbox.bottom >= e.y) {
          
          result.startOffset = result.startOffset - 1;
          adjustIndex = true;
      }
    }
  
  
  while (paragraph && paragraph.nodeName !== 'P') {
    paragraph = paragraph.parentNode;
  }
  if (paragraph === null) {
    paragraph = result.startContainer.parentNode;
  }
  var noFuriganaText = [];
  var noFuriganaNodes = [];
  var selectedFound = false;
  var index = 0;
  for (var value of paragraph.childNodes.values()) {
    if (value.nodeName === "#text") {
      noFuriganaText.push(value.textContent);
      noFuriganaNodes.push(value);
      if (selectedFound === false) {
        if (selectedElement !== value) {
          index = index + value.textContent.length;
        } else {
          index = index + result.startOffset;
          selectedFound = true;
        }
      }
    } else {
      for (var node of value.childNodes.values()) {
        if (node.nodeName === "#text") {
          noFuriganaText.push(node.textContent);
          noFuriganaNodes.push(node);
          if (selectedFound === false) {
            if (selectedElement !== node) {
              index = index + node.textContent.length;
            } else {
              index = index + result.startOffset;
              selectedFound = true;
            }
          }
        } else if (node.firstChild.nodeName === "#text" && node.nodeName !== "RT" && node.nodeName !== "RP") {
          noFuriganaText.push(node.firstChild.textContent);
          noFuriganaNodes.push(node.firstChild);
          if (selectedFound === false) {
            if (selectedElement !== node.firstChild) {
              index = index + node.firstChild.textContent.length;
            } else {
              index = index + result.startOffset;
              selectedFound = true;
            }
          }
        }
      }
    }
  }
  var text = noFuriganaText.join("");
  var offset = index;
  if (adjustIndex) {
    index = index - 1;
  }
  

  var character = text[index];
  if (character) {
    console.log(JSON.stringify({
      "index": index,
      "text": text,
      "jidoujisho-message-type": "lookup",
      "x": e.clientX,
      "y": e.clientY,
    }));
    console.log(character);
  } else {
    console.log(JSON.stringify({
      "index": -1,
      "text": getSelectionText(),
      "jidoujisho-message-type": "lookup",
      "x": e.clientX,
      "y": e.clientY,
      "isCreator": "no",
    }));
  }
}
function getSelectionText() {
    function getRangeSelectedNodes(range) {
      var node = range.startContainer;
      var endNode = range.endContainer;
      if (node == endNode) return [node];
      var rangeNodes = [];
      while (node && node != endNode) rangeNodes.push(node = nextNode(node));
      node = range.startContainer;
      while (node && node != range.commonAncestorContainer) {
        rangeNodes.unshift(node);
        node = node.parentNode;
      }
      return rangeNodes;
      function nextNode(node) {
        if (node.hasChildNodes()) return node.firstChild;
        else {
          while (node && !node.nextSibling) node = node.parentNode;
          if (!node) return null;
          return node.nextSibling;
        }
      }
    }
    var txt = "";
    var nodesInRange;
    var selection;
    if (window.getSelection) {
      selection = window.getSelection();
      nodesInRange = getRangeSelectedNodes(selection.getRangeAt(0));
      nodes = nodesInRange.filter((node) => node.nodeName == "#text" && node.parentElement.nodeName !== "RT" && node.parentElement.nodeName !== "RP" && node.parentElement.parentElement.nodeName !== "RT" && node.parentElement.parentElement.nodeName !== "RP");
      if (selection.anchorNode === selection.focusNode) {
          txt = txt.concat(selection.anchorNode.textContent.substring(selection.baseOffset, selection.extentOffset));
      } else {
          for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (i === 0) {
                  txt = txt.concat(node.textContent.substring(selection.getRangeAt(0).startOffset));
              } else if (i === nodes.length - 1) {
                  txt = txt.concat(node.textContent.substring(0, selection.getRangeAt(0).endOffset));
              } else {
                  txt = txt.concat(node.textContent);
              }
          }
      }
    } else if (window.document.getSelection) {
      selection = window.document.getSelection();
      nodesInRange = getRangeSelectedNodes(selection.getRangeAt(0));
      nodes = nodesInRange.filter((node) => node.nodeName == "#text" && node.parentElement.nodeName !== "RT" && node.parentElement.nodeName !== "RP" && node.parentElement.parentElement.nodeName !== "RT" && node.parentElement.parentElement.nodeName !== "RP");
      if (selection.anchorNode === selection.focusNode) {
          txt = txt.concat(selection.anchorNode.textContent.substring(selection.baseOffset, selection.extentOffset));
      } else {
          for (var i = 0; i < nodes.length; i++) {
              var node = nodes[i];
              if (i === 0) {
                  txt = txt.concat(node.textContent.substring(selection.getRangeAt(0).startOffset));
              } else if (i === nodes.length - 1) {
                  txt = txt.concat(node.textContent.substring(0, selection.getRangeAt(0).endOffset));
              } else {
                  txt = txt.concat(node.textContent);
              }
          }
      }
    } else if (window.document.selection) {
      txt = window.document.selection.createRange().text;
    }
    return txt;
};
var reader = document.getElementsByClassName('book-content');
if (reader.length != 0) {
  reader[0].addEventListener('click', tapToSelect, true);
}
document.head.insertAdjacentHTML('beforebegin', `
<style>
rt {
  -webkit-touch-callout:none; /* iOS Safari */
  -webkit-user-select:none;   /* Chrome/Safari/Opera */
  -khtml-user-select:none;    /* Konqueror */
  -moz-user-select:none;      /* Firefox */
  -ms-user-select:none;       /* Internet Explorer/Edge */
  user-select:none;           /* Non-prefixed version */
}
rp {
  -webkit-touch-callout:none; /* iOS Safari */
  -webkit-user-select:none;   /* Chrome/Safari/Opera */
  -khtml-user-select:none;    /* Konqueror */
  -moz-user-select:none;      /* Firefox */
  -ms-user-select:none;       /* Internet Explorer/Edge */
  user-select:none;           /* Non-prefixed version */
}

::selection {
  color: white;
  background: rgba(255, 0, 0, 0.6);
}
</style>
`);


function selectTextForTextLength(x, y, index, length, whitespaceOffset, isSpaceDelimited) {
  var result = document.caretRangeFromPoint(x, y);

  var selectedElement = result.startContainer;
  var paragraph = result.startContainer;
  var offsetNode = result.startContainer;
  var offset = result.startOffset;

  var adjustIndex = false;

  if (!!offsetNode && offsetNode.nodeType === Node.TEXT_NODE && offset) {
      const range = new Range();
      range.setStart(offsetNode, offset - 1);
      range.setEnd(offsetNode, offset);

      const bbox = range.getBoundingClientRect();
      if (bbox.left <= x && bbox.right >= x &&
          bbox.top <= y && bbox.bottom >= y) {
          if (length == 1) {
            const range = new Range();
            range.setStart(offsetNode, result.startOffset - 1);
            range.setEnd(offsetNode, result.startOffset);

            var selection = window.getSelection();
            selection.removeAllRanges();
            selection.addRange(range);
            return;
          }

          result.startOffset = result.startOffset - 1;
          adjustIndex = true;
      }
  }

  if (length == 1) {
    const range = new Range();
    range.setStart(offsetNode, result.startOffset);
    range.setEnd(offsetNode, result.startOffset + 1);

    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    return;
  }

  while (paragraph && paragraph.nodeName !== 'P') {
    paragraph = paragraph.parentNode;
  }
  if (paragraph === null) {
    paragraph = result.startContainer.parentNode;
  }
  var noFuriganaText = [];
  var lastNode;

  var endOffset = 0;
  var done = false;

  for (var value of paragraph.childNodes.values()) {
    if (done) {
      console.log(noFuriganaText.join());
      break;
    }
    
    if (value.nodeName === "#text") {
      endOffset = 0;
      lastNode = value;
      for (var i = 0; i < value.textContent.length; i++) {
        noFuriganaText.push(value.textContent[i]);
        endOffset = endOffset + 1;
        if (noFuriganaText.length >= length + index) {
          done = true;
          break;
        }
      }
    } else {
      for (var node of value.childNodes.values()) {
        if (done) {
          break;
        }

        if (node.nodeName === "#text") {
          endOffset = 0;
          lastNode = node;

          for (var i = 0; i < node.textContent.length; i++) {
            noFuriganaText.push(node.textContent[i]);
            endOffset = endOffset + 1;
            if (noFuriganaText.length >= length + index) {
              done = true;
              break;
            }
          }
        } else if (node.firstChild.nodeName === "#text" && node.nodeName !== "RT" && node.nodeName !== "RP") {
          endOffset = 0;
          lastNode = node.firstChild;
          for (var i = 0; i < node.firstChild.textContent.length; i++) {
            noFuriganaText.push(node.firstChild.textContent[i]);
            endOffset = endOffset + 1;
            if (noFuriganaText.length >= length + index) {
              done = true;
              break;
            }
          }
        }
      }
    }
  }

  const range = new Range();
  range.setStart(offsetNode, result.startOffset - adjustIndex + whitespaceOffset);
  if (isSpaceDelimited) {
    range.expand("word");
  } else {
    range.setEnd(lastNode, endOffset);
  }
  
  var selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
}
""";

  String get leftArrowSimulateJs => '''
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true); 
    evt.deltaY = +0.001 * ${mediaSource.volumePageTurningSpeed * (mediaSource.volumePageTurningInverted ? -1 : 1)};
    document.body.dispatchEvent(evt); 
    ''';

  String get rightArrowSimulateJs => '''
    var evt = document.createEvent('MouseEvents');
    evt.initEvent('wheel', true, true); 
    evt.deltaY = -0.001 * ${mediaSource.volumePageTurningSpeed * (mediaSource.volumePageTurningInverted ? -1 : 1)};
    document.body.dispatchEvent(evt); 
    ''';
}
