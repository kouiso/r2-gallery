import 'dart:convert';

/// `r2g://setup?e=<endpoint>#<token>` のペアリング文字列が運ぶ接続情報。
/// トークンはフラグメントに載せる。サーバーのアクセスログへ残さないため、ここから動かさない。
class PairingConfig {
  final String endpoint;
  final String token;
  const PairingConfig(this.endpoint, this.token);
}

const _scheme = 'r2g://';
const _host = 'setup';

// decodeURIComponent と同じく、strict では壊れた % を弾く。
// e= は form 形式でも来るので '+' を空白に戻す版も持つ（KMP 版 percentDecode と同じ）
String? _percentDecode(
  String s, {
  required bool plusAsSpace,
  required bool strict,
}) {
  final out = <int>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '%' && i + 2 < s.length) {
      final h = int.tryParse(s.substring(i + 1, i + 3), radix: 16);
      if (h != null) {
        out.add(h);
        i += 3;
        continue;
      }
    }
    if (c == '%' && strict) return null;
    if (c == '+' && plusAsSpace) {
      out.add(0x20);
      i++;
      continue;
    }
    out.addAll(utf8.encode(c));
    i++;
  }
  return utf8.decode(out, allowMalformed: true);
}

/// エンドポイントを `origin + path`（末尾スラッシュなし）にそろえる。
/// 認証情報・クエリ・フラグメントの付いたものや https 以外は null。
/// tools/pairing-url.mjs と KMP 版 normalizeEndpoint と同じ判定にしてある。
String? normalizeEndpoint(String raw) {
  final s = raw.trim();
  if (!s.startsWith('https://')) return null;
  final rest = s.substring('https://'.length);
  if (rest.isEmpty) return null;
  final i = rest.indexOf(RegExp(r'[/?#]'));
  final authority = i < 0 ? rest : rest.substring(0, i);
  final path = i < 0 ? '' : rest.substring(i);
  if (authority.isEmpty || authority.contains('@') || authority.contains(' ')) {
    return null;
  }
  final host = authority.split(':').first;
  if (host.isEmpty) return null;
  if (path.contains('?') || path.contains('#')) return null;
  return 'https://$authority${path.replaceAll(RegExp(r'/+$'), '')}';
}

/// ペアリング文字列を読む。形が少しでも崩れていれば null（例外は投げない）。
PairingConfig? parsePairingString(String input) {
  final s = input.trim();
  if (!s.startsWith(_scheme)) return null;
  final rest = s.substring(_scheme.length);

  final hash = rest.indexOf('#');
  if (hash < 0) return null;
  final beforeHash = rest.substring(0, hash);
  final frag = rest.substring(hash + 1);
  if (frag.isEmpty) return null;
  final token = _percentDecode(frag, plusAsSpace: false, strict: true);
  if (token == null || token.isEmpty) return null;

  final hostEnd = beforeHash.indexOf(RegExp(r'[/?]'));
  final host = (hostEnd < 0 ? beforeHash : beforeHash.substring(0, hostEnd))
      .split(':')
      .first;
  if (host.toLowerCase() != _host) return null;

  final qi = beforeHash.indexOf('?');
  if (qi < 0) return null;
  String? e;
  for (final part in beforeHash.substring(qi + 1).split('&')) {
    final eq = part.indexOf('=');
    final k = eq < 0 ? part : part.substring(0, eq);
    if (k == 'e') {
      e = eq < 0 ? '' : part.substring(eq + 1);
      break;
    }
  }
  if (e == null) return null;
  final decoded = _percentDecode(e, plusAsSpace: true, strict: false);
  if (decoded == null) return null;
  final endpoint = normalizeEndpoint(decoded);
  if (endpoint == null) return null;
  return PairingConfig(endpoint, token);
}

/// ペアリング文字列を作る（parsePairingString の逆）。tools/pairing-url.mjs と同じ出力。
String buildPairingString(String endpoint, String token) {
  final norm = normalizeEndpoint(endpoint);
  if (norm == null) {
    throw ArgumentError.value(
      endpoint,
      'endpoint',
      'https:// で、認証情報・クエリ・フラグメントの無い URL にしてください',
    );
  }
  if (token.trim().isEmpty) {
    throw ArgumentError.value(token, 'token', '空にはできません');
  }
  return 'r2g://setup?e=${Uri.encodeComponent(norm)}#${Uri.encodeComponent(token)}';
}

/// 手入力の補正。貼り付けた末尾の改行や空白、ホスト名だけの入力で接続に失敗させない。
/// トークンは平文で流せないので https 以外は null（KMP 版 connect と同じ補正）。
({String endpoint, String token})? normalizeConnectInput(
  String endpoint,
  String token,
) {
  var ep = endpoint.trim().replaceAll(RegExp(r'/+$'), '');
  final tk = token.trim();
  if (ep.isNotEmpty && !ep.contains('://')) ep = 'https://$ep';
  if (!ep.startsWith('https://') ||
      ep.length == 'https://'.length ||
      tk.isEmpty) {
    return null;
  }
  return (endpoint: ep, token: tk);
}

/// 表示用のホスト名。スキームとパスを落とし、トークンや userinfo は決して出さない。
String hostOf(String endpoint) {
  final noScheme = endpoint.trim().replaceFirst(
    RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://'),
    '',
  );
  // userinfo に / ? # が生で入った壊れた URL でも漏らさんよう、先に最後の @ までを落とす
  final at = noScheme.lastIndexOf('@');
  final afterAt = at < 0 ? noScheme : noScheme.substring(at + 1);
  final end = afterAt.indexOf(RegExp(r'[/?#]'));
  return end < 0 ? afterAt : afterAt.substring(0, end);
}
