import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../webdl/detected.dart';
import '../webdl/detected_thumb.dart';
import '../webdl/url_policy.dart';
import '../webdl/web_history.dart';
import 'browser_surface.dart';
import 'import_parts.dart';
import 'theme.dart';

/// 取り込みタブ。動画ダウンローダ系アプリの要領で、内蔵ブラウザで開いたページから
/// メディアを検出し、タップで端末→R2 に取り込む。KMP 版 ImportBrowserScreen.kt に対応。
class ImportBrowserTab extends StatefulWidget {
  final AppState app;
  /// 内蔵ブラウザを開いた・閉じた時。開いている間、外側は下タブを隠す（#165）
  final ValueChanged<bool>? onBrowserOpenChanged;
  /// 戻るの問い合わせ先。テストでは WebView が無いので、履歴の有無を決めた物を渡す
  @visibleForTesting
  final BrowserBack? back;
  const ImportBrowserTab(
      {super.key, required this.app, this.onBrowserOpenChanged, this.back});

  @override
  State<ImportBrowserTab> createState() => _ImportBrowserTabState();
}

class _ImportBrowserTabState extends State<ImportBrowserTab> {
  final _url = TextEditingController();
  final _urlFocus = FocusNode();
  String _loadedUrl = '';
  int _nonce = 0;
  final _detected = ValueNotifier<List<DetectedItem>>(const []);
  late final BrowserBack _back = widget.back ?? BrowserBack();
  // 取得はブラウザと同じ UA / Referer / Cookie の扱いにするため、取り込みと同じ取得役を使う
  late final _thumbs = DetectedThumbs(fetcher: app.webQueue.fetcher);

  AppState get app => widget.app;

  @override
  void dispose() {
    _url.dispose();
    _urlFocus.dispose();
    _detected.dispose();
    super.dispose();
  }

  void _clearUrl() {
    // 入力欄の文字だけ消す。開いているページと検出一覧は残し、すぐ打ち直せるようにカーソルを戻す
    _url.clear();
    _urlFocus.requestFocus();
  }

  void _go() {
    if (_url.text.trim().isEmpty) return;
    final u = normalizeBrowserInput(_url.text);
    if (u == null) {
      // file: や javascript: などは開かない。内蔵ブラウザから端末内や他アプリへ抜けさせんため
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('http/https のページだけ開けます')));
      return;
    }
    FocusScope.of(context).unfocus();
    final opening = _loadedUrl.isEmpty;
    setState(() {
      _loadedUrl = u;
      _nonce++;
    });
    if (opening) widget.onBrowserOpenChanged?.call(true);
  }

  // ブラウザを閉じて URL 入力の画面に戻す。検出一覧も前のページの物なので空にする
  void _closeBrowser() {
    if (_loadedUrl.isEmpty) return;
    setState(() => _loadedUrl = '');
    _detected.value = const [];
    widget.onBrowserOpenChanged?.call(false);
  }

  void _onDetected(List<DetectedItem> items) {
    final seen = <String>{};
    final next = [
      for (final d in items)
        if (seen.add(d.url)) d,
    ];
    if (!mounted) return;
    _detected.value = next;
  }

  SaveBlock? _block() {
    final lib = app.activeLib;
    // 一覧に無い保存先は、読み取り専用か分からないので「保存先なし」として止める
    final found = lib != null && app.libraries.any((l) => l.id == lib);
    final readOnly = found && app.libraries.firstWhere((l) => l.id == lib).readOnly;
    return saveBlockFor(
        libFound: found, hasConnection: app.connected, libReadOnly: readOnly);
  }

  Future<void> _save(DetectedItem d) async {
    if (_block() != null) return;
    final lib = app.activeLib;
    if (lib == null) return;
    Navigator.of(context).pop();
    final dup = await app.webQueue.findDuplicate(lib, d.url);
    if (!mounted) return;
    if (dup != null && !await confirmDuplicateImport(context, dup)) return;
    if (!mounted) return;
    final added = app.webQueue.enqueue(lib, [d]);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(added.isEmpty
            ? 'すでに転送中です: ${d.displayName}'
            : '転送キューに追加: ${d.displayName}')));
  }

  void _openDetected() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surfaceHigh,
      builder: (ctx) => ValueListenableBuilder<List<DetectedItem>>(
        valueListenable: _detected,
        builder: (ctx, items, _) {
          if (items.isEmpty) {
            // ページの再読み込みなどで検出が0件に戻ったら、空のシートを残さない
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted && Navigator.of(ctx).canPop()) {
                Navigator.of(ctx).pop();
              }
            });
            return const SizedBox.shrink();
          }
          return DetectedSheetContent(
              items: items, block: _block(), onSave: _save, thumbs: _thumbs);
        },
      ),
    );
  }

  Future<void> _openHistory() async {
    final List<WebHistoryEntry> entries = await app.webQueue.history.list();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ダウンロード履歴'),
        content: HistoryList(entries: entries),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('閉じる')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      // 内蔵ブラウザは端末のネイティブ WebView が要る。Web 版には無いのでその旨を出す
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'ネットからの取り込みは Android アプリで使えます（Web 版では利用できません）',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textDim),
          ),
        ),
      );
    }
    final browserOpen = _loadedUrl.isNotEmpty;
    return PopScope(
      // ブラウザ表示中の戻るは、ページを戻れる間はページを戻し、戻れなければブラウザを閉じる
      canPop: !browserOpen,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !browserOpen) return;
        if (await _back.canGoBack()) {
          _back.goBack();
        } else if (mounted) {
          _closeBrowser();
        }
      },
      child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        children: [
          Row(
            children: [
              if (browserOpen)
                IconButton(
                  tooltip: 'ブラウザを閉じる',
                  icon: const Icon(Icons.close),
                  onPressed: _closeBrowser,
                ),
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text('ネットから取り込む',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              IconButton(
                tooltip: 'ダウンロード履歴',
                icon: const Icon(Icons.history),
                onPressed: _openHistory,
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _url,
                  builder: (context, value, _) => TextField(
                    controller: _url,
                    focusNode: _urlFocus,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _go(),
                    decoration: InputDecoration(
                      hintText: 'https://…',
                      isDense: true,
                      // 空の時に出しても押す意味が無いので、文字がある時だけ出す
                      suffixIcon: value.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '入力を消す',
                              icon: const Icon(Icons.close),
                              onPressed: _clearUrl,
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _go,
                child: const Icon(Icons.public, semanticLabel: '移動'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loadedUrl.isEmpty
                // URL を入れるまで WebView を作らない。空の WebView が面全体を覆ってタップを食うのを避ける
                ? const Center(
                    child: Text('動画ページのURLを入力して移動',
                        style: TextStyle(color: AppColors.textDim)),
                  )
                : BrowserSurface(
                    url: _loadedUrl,
                    nonce: _nonce,
                    onDetected: _onDetected,
                    back: _back,
                  ),
          ),
          ValueListenableBuilder<List<DetectedItem>>(
            valueListenable: _detected,
            builder: (context, items, _) => items.isEmpty
                ? const SizedBox(height: 8)
                : Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child:
                        DetectionBar(count: items.length, onTap: _openDetected),
                  ),
          ),
        ],
      ),
      ),
    );
  }
}
