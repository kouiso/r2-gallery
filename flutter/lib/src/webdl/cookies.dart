import 'package:flutter/services.dart';

import 'url_policy.dart';

/// 内蔵ブラウザ（Android WebView）の Cookie を引く口。webview_flutter は Cookie の読み出しを
/// 公開しておらず、HttpOnly の Cookie は JS からも見えんので、Android 側の CookieManager を直接引く。
/// Dart からしか呼べず、閲覧中のページからは届かない。
const _cookieChannel = MethodChannel('app.r2gallery/cookies');

/// [url] に送る Cookie。ブラウザと同じく、その URL のホストに属するものだけが返る。
/// 口が無い環境（テスト・Web 版）や http/https 以外では null。
Future<String?> webViewCookieFor(String url) async {
  if (!isWebUrl(url)) return null;
  try {
    final c = await _cookieChannel.invokeMethod<String>('get', url);
    return (c == null || c.isEmpty) ? null : c;
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}
