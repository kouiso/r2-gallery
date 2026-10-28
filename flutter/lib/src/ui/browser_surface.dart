import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../webdl/cookies.dart';
import '../webdl/detected.dart';
import '../webdl/sniff_collector.dart';
import '../webdl/url_policy.dart';
import 'app_lock_layer.dart';
import 'theme.dart';

/// ページに差し込む見張り役。KMP 版は WebView の shouldInterceptRequest で通信を直接見ていたが、
/// webview_flutter は通信の横取りを公開していないので、ページ側でリソース通信を拾って
/// JS チャンネルで Dart に渡す。送るのは [種別, URL] の組をまとめた配列。
/// 種別 s = 通信（Resource Timing / fetch / XHR）、p = ページ内の要素（img / video / audio / source）。
/// v = video 要素の詳細。[要素, URL, 表紙URL, タイトル] の4つ組で、一覧がサイト上の見た目と
/// 同じ表紙・名前を出せるようにする（通信で拾った同じ URL の検出にも足される）。
/// f = video 要素がデコードした実コマ。[要素, URL, JPEGのdataURL] の3つ組。表紙より
/// 動画の実体が分かる物を優先して一覧のサムネにする。canvas が汚れて取れない
/// 別ドメイン動画（CORS 無し）は送ってこないので、そこは取得役でのコマ抜きに回る。
const _hookJs = r'''
(function(){
  if (window.__r2sniff) { window.__r2scan && window.__r2scan(); return; }
  window.__r2sniff = true;
  var MEDIA=/\.(mp4|webm|mkv|mov|m4v|avi|flv|3gp|mpg|mpeg|wmv|ts|mp3|m4a|aac|ogg|opus|wav|flac)(\?|#|$)/i;
  var HLS=/\.m3u8(\?|#|$)/i;
  var seen={}, queue=[], timer=null;
  function abs(u){ try{ return new URL(u, document.baseURI).href; }catch(e){ return ''; } }
  function flush(){ timer=null; if(!queue.length) return; var q=queue; queue=[]; R2Sniff.postMessage(JSON.stringify(q)); }
  function push(k,u){
    u=abs(u); if(!/^https?:/i.test(u)) return;
    var id=k+u; if(seen[id]) return; seen[id]=1;
    queue.push([k,u]); if(!timer) timer=setTimeout(flush,250);
  }
  // 動画の URL に表紙とタイトルを添えて送る。表紙・タイトルが後から付くこともあるので
  // 値の変わった組は再度送る（seen のキーに値も入れる）
  function pushv(u,poster,label){
    u=abs(u); if(!/^https?:/i.test(u)) return;
    var id='v'+u+'|'+poster+'|'+label; if(seen[id]) return; seen[id]=1;
    queue.push(['v',u,poster,label]); if(!timer) timer=setTimeout(flush,250);
  }
  // video 要素のまわりから人間向けの名前を拾う。動画が1本だけ入った入れ物の
  // キャプション・見出し・title 属性だけを使う（動画が複数ある入れ物だと別の動画の名前を拾ってしまう）
  function ctxText(v){
    var t=(v.getAttribute('title')||v.getAttribute('aria-label')||'').trim();
    if(t) return t.slice(0,160);
    var a=v.closest&&v.closest('a');
    if(a){ t=(a.getAttribute('title')||'').trim(); if(t) return t.slice(0,160); }
    var f=v.closest&&v.closest('figure');
    if(f){ var c=f.querySelector('figcaption'); t=c?String(c.textContent||'').trim():''; if(t) return t.slice(0,160); }
    var p=v.parentElement, d=0;
    while(p && p.querySelectorAll && d<4){
      if(p.querySelectorAll('video,audio').length===1){
        var c=p.querySelector('figcaption,h1,h2,h3,h4');
        if(c){ t=String(c.textContent||'').trim(); if(t) return t.slice(0,160); }
        var te=p.querySelector('[title]');
        if(te){ t=(te.getAttribute('title')||'').trim(); if(t) return t.slice(0,160); }
        t=(p.getAttribute&&p.getAttribute('title')||'').trim(); if(t) return t.slice(0,160);
      }
      p=p.parentElement; d++;
    }
    return '';
  }
  function res(u){ if(typeof u==='string' && (MEDIA.test(u)||HLS.test(u))) push('s',u); }
  // その video が既にデコードしている 1 コマを canvas に描いて送る。
  // CORS 無しの別ドメイン動画は canvas が汚れて dataURL を出せず、ここで黙って諦める
  // （Dart 側で動画本体の先頭を取ってコマを抜く経路が残る）。目盛りの移動や再生は触らない
  function pushf(v,u){
    try{
      if(v.readyState<2 || !v.videoWidth) return;
      var w=Math.min(v.videoWidth,320), h=Math.max(1,Math.round(w*v.videoHeight/v.videoWidth));
      var c=document.createElement('canvas'); c.width=w; c.height=h;
      c.getContext('2d').drawImage(v,0,0,w,h);
      var d=c.toDataURL('image/jpeg',0.6);
      // チャンネル越しに送る文字列なので、どうしても大きい物は諦める
      if(d.length>200000) return;
      u=abs(u); if(!/^https?:/i.test(u)) return;
      var id='f'+u; if(seen[id]) return; seen[id]=1;
      queue.push(['f',u,d]); if(!timer) timer=setTimeout(flush,250);
    }catch(e){}
  }
  function scan(){
    try{
      document.querySelectorAll('img').forEach(function(e){var s=e.currentSrc||e.src; if(s) push('p',s)});
      document.querySelectorAll('video').forEach(function(v){
        // 未設定の poster を abs() に通すとページの URL になるので、有る時だけ解決する
        var poster=v.poster||v.getAttribute('poster')||'';
        poster=poster?abs(poster):'';
        var label=ctxText(v);
        var srcs=[];
        if(v.currentSrc) srcs.push(v.currentSrc); if(v.src) srcs.push(v.src);
        v.querySelectorAll('source').forEach(function(s){ if(s.src) srcs.push(s.src) });
        srcs.forEach(function(s){ pushv(s,poster,label) });
        // 実コマは「絵が出る状態になった時」に1回だけ取る。まだ読めていなければ
        // 最初のコマが出た所で送る（preload=none でずっと読まない物はそのまま）。
        // 送り先の URL は取る時点で拾い直す（走査の時は src がまだ無く、後から
        // スクリプトで付く動画があるため）
        if(!v.__r2f){ v.__r2f=1;
          var grab=function(){
            var ss=[];
            if(v.currentSrc) ss.push(v.currentSrc); if(v.src) ss.push(v.src);
            v.querySelectorAll('source').forEach(function(s){ if(s.src) ss.push(s.src) });
            ss.forEach(function(s){ pushf(v,s) });
          };
          if(v.readyState>=2) grab(); else v.addEventListener('loadeddata',grab,{once:true});
        }
      });
      document.querySelectorAll('audio').forEach(function(v){
        // 音声にもカードのタイトルを添える（表紙は無い）
        var label=ctxText(v);
        if(v.currentSrc) pushv(v.currentSrc,'',label); if(v.src) pushv(v.src,'',label);
        v.querySelectorAll('source').forEach(function(s){ if(s.src) pushv(s.src,'',label) });
      });
      performance.getEntriesByType('resource').forEach(function(r){ res(r.name||'') });
    }catch(e){}
  }
  window.__r2scan=scan;
  try{ new PerformanceObserver(function(l){ l.getEntries().forEach(function(r){ res(r.name||'') }); }).observe({type:'resource',buffered:true}); }catch(e){}
  try{
    var of=window.fetch;
    if(of) window.fetch=function(i){ try{ res(typeof i==='string'?i:(i&&i.url)); }catch(e){} return of.apply(this,arguments); };
    var ox=XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open=function(m,u){ try{ res(abs(String(u))); }catch(e){} return ox.apply(this,arguments); };
  }catch(e){}
  // 後から差し込まれるプレイヤーも拾う。連続する変化は間引く
  var mt=null;
  try{ new MutationObserver(function(){ if(mt) return; mt=setTimeout(function(){ mt=null; scan(); },500); })
    .observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['src','poster','title','aria-label']}); }catch(e){}
  scan();
})();
''';

// ロックで画面を隠しても、ページの動画・音声は鳴り続ける。隠すのと一緒に止める
const _pauseJs = r'''
(function(){ try{ document.querySelectorAll('video,audio').forEach(function(m){ m.pause(); }); }catch(e){} })();
''';

/// 1回の通知で受け取る件数の上限。ページは信用できんので、巨大な配列で固まらんようにする。
const _maxPairsPerMessage = 200;

/// 端末の「戻る」をページの戻るにつなぐための窓口。外側の画面が持ち、[BrowserSurface] が中身を入れる。
class BrowserBack {
  Future<bool> Function()? _canGoBack;
  VoidCallback? _goBack;

  /// 押された時点の WebView の履歴を聞く。読み込み途中や pushState で増えた履歴も見落とさんように、
  /// 最後に読み終えたページで覚えた値は使わない
  Future<bool> canGoBack() async => await _canGoBack?.call() ?? false;
  void goBack() => _goBack?.call();

  /// 表示中の WebView につなぐ。[BrowserSurface] が作られた時に呼ぶ
  void bind(
      {required Future<bool> Function() canGoBack,
      required VoidCallback goBack}) {
    _canGoBack = canGoBack;
    _goBack = goBack;
  }

  /// 閉じた後の戻るが、消えた WebView に問い合わせんようにする
  void unbind() {
    _canGoBack = null;
    _goBack = null;
  }
}

/// ネット取り込み用の内蔵ブラウザ。ページが再生するメディアを拾い、
/// 検出一覧が変わるたびに [onDetected] へ渡す。KMP 版 BrowserSurface.android.kt に対応。
class BrowserSurface extends StatefulWidget {
  /// 表示するページ。[nonce] が変わるたびに（同じ URL でも）読み込み直す。
  final String url;
  final int nonce;
  final ValueChanged<List<DetectedItem>> onDetected;
  final BrowserBack? back;
  const BrowserSurface({
    super.key,
    required this.url,
    required this.nonce,
    required this.onDetected,
    this.back,
  });

  @override
  State<BrowserSurface> createState() => _BrowserSurfaceState();
}

class _BrowserSurfaceState extends State<BrowserSurface>
    with PauseOnLock<BrowserSurface> {
  WebViewController? _controller;
  final SniffCollector _collector = SniffCollector();
  String _pageUrl = '';
  String _userAgent = '';
  // 古いページから遅れて届いた検出を、移動後のページに混ぜんための世代
  int _gen = 0;
  String? _error;
  bool _canGoBack = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    widget.back?.bind(
      canGoBack: () async => await _controller?.canGoBack() ?? false,
      goBack: () => _controller?.goBack(),
    );
    _create();
  }

  @override
  void dispose() {
    widget.back?.unbind();
    super.dispose();
  }

  @override
  void didUpdateWidget(BrowserSurface old) {
    super.didUpdateWidget(old);
    if (old.nonce != widget.nonce || old.url != widget.url) _load();
  }

  void _create() {
    try {
      final c = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel('R2Sniff', onMessageReceived: _onMessage)
        ..setNavigationDelegate(NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onUrlChange: (c) {
            if (c.url != null) _pageUrl = c.url!;
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? false) {
              if (mounted) setState(() => _error = e.description);
            }
          },
        ));
      _controller = c;
      c.getUserAgent().then((ua) => _userAgent = ua ?? '');
      _load();
    } catch (e) {
      // WebView の提供元が無い・更新中などで作れない。真っ黒な面にせず、再試行できる表示にする
      _error = e.runtimeType.toString();
    }
  }

  void _load() {
    final c = _controller;
    if (c == null) return;
    _error = null;
    // 入力欄で弾いているが、ここでも http/https 以外は開かない
    if (!isWebUrl(widget.url)) {
      _error = 'http/https のページだけ開けます';
      return;
    }
    c.loadRequest(Uri.parse(widget.url));
  }

  // ページ内のリンクやリダイレクトで file: / intent: / 独自スキームへ抜けんようにする。
  // 外部アプリを開く口が無いので、ここからアプリの外へ出る画面（ロック猶予の対象）も生まれない
  NavigationDecision _onNavigationRequest(NavigationRequest r) {
    if (isWebUrl(r.url) || r.url == 'about:blank') {
      return NavigationDecision.navigate;
    }
    if (r.isMainFrame && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text('このリンクはアプリ内ブラウザでは開けません')));
    }
    return NavigationDecision.prevent;
  }

  @override
  void onLocked() {
    _runJs(_pauseJs);
  }

  // 読み込み途中や閉じた後のページでは失敗することがある。見張りが1回入らんだけなので記録して進む
  void _runJs(String js) {
    final c = _controller;
    if (c == null) return;
    unawaited(c.runJavaScript(js).then((_) {}, onError: (Object e) {
      debugPrint('browser js skipped: $e');
    }));
  }

  void _report() {
    if (mounted) widget.onDetected(_collector.list());
  }

  void _onPageStarted(String url) {
    _pageUrl = url;
    _gen++;
    // 新しいページへ移ったら前のページの検出は捨てる。件数が今のページのものだけになるように
    _collector.clear();
    _report();
    if (mounted) setState(() => _loading = true);
    _runJs(_hookJs);
  }

  Future<void> _onPageFinished(String url) async {
    _pageUrl = url;
    if (!mounted) return;
    final back = await _controller?.canGoBack() ?? false;
    if (mounted) {
      setState(() {
        _loading = false;
        _canGoBack = back;
      });
    }
    _runJs(_hookJs);
  }

  Future<void> _onMessage(JavaScriptMessage m) async {
    final gen = _gen;
    final Object? decoded;
    try {
      decoded = jsonDecode(m.message);
    } on FormatException {
      // ページは R2Sniff へ何でも送れる。形の違う通知は捨てる
      return;
    }
    if (decoded is! List) return;
    final pairs = decoded;
    for (final p in pairs.take(_maxPairsPerMessage)) {
      if (p is! List || p.length < 2) continue;
      final kind = p[0];
      final url = p[1];
      // ページは R2Sniff へ何でも送れる。http/https 以外は拾わない
      if (url is! String || !isWebUrl(url)) continue;
      // 取得に要る Cookie を、拾った瞬間のページの状態で引いておく（取得時にも送り先ごとに引き直す）
      final cookie = await webViewCookieFor(url);
      if (gen != _gen || !mounted) return;
      final headers = {
        if (_userAgent.isNotEmpty) 'User-Agent': _userAgent,
        if (_pageUrl.isNotEmpty) 'Referer': _pageUrl,
        if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
      };
      if (kind == 's') {
        _collector.capture(url, headers);
      } else if (kind == 'f') {
        // 'f' は [要素, URL, 実コマの dataURL] の3つ組
        final frame = p.length > 2 && p[2] is String ? p[2] as String : '';
        _collector.addFromPage(url, headers, frame: frame);
      } else {
        // 'v' は [要素, URL, 表紙URL, タイトル] の4つ組。余分な要素が無くても読めるようにする
        final poster = p.length > 2 && p[2] is String ? p[2] as String : '';
        final label = p.length > 3 && p[3] is String ? p[3] as String : '';
        _collector.addFromPage(url, headers, poster: poster, label: label);
      }
    }
    _report();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null || _controller == null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('内蔵ブラウザを開けませんでした: ${_error ?? ''}',
                style: const TextStyle(color: AppColors.textDim)),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _error = null;
                if (_controller == null) {
                  _create();
                } else {
                  _load();
                }
              }),
              child: const Text('再試行'),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: ClipRect(child: WebViewWidget(controller: _controller!)),
        ),
        if (_canGoBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _controller?.goBack(),
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('戻る'),
            ),
          ),
      ],
    );
  }
}
