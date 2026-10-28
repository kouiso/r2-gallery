import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/viewer_screen.dart';
import 'package:r2_gallery/src/ui/theme.dart';

late final HttpServer server;
late final AppState app;
String mode = 'review';
int calls = 0;
Map<String, Object?> review(String label) => {
  'verdict': 'adopted', 'round': 2, 'label': label,
  'intentComment': 'Safe fixture only', 'directorScore': 9,
  'directorComment': 'Overall fixture comment',
  'criteria': [
    {'key': 'lighting', 'panelScore': 7, 'directorScore': 9,
     'comment': 'Criterion fixture comment'},
    {'key': 'framing', 'panelScore': 8, 'veto': true, 'comment': null},
  ],
};
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((r) async {
    r.response.headers.contentType = ContentType.json;
    if (r.uri.path.endsWith('/meta')) {
      final n = ++calls;
      final thisMode = mode;
      final key = r.uri.queryParameters['key'];
      if (thisMode == 'failure' && n <= 3) {
        r.response.statusCode = 503;
        r.response.write('{}');
      } else {
        String label = 'Fixture review';
        if (thisMode == 'race') {
          label = key == 'a.txt' ? (n == 1 ? 'STALE A' : 'LATEST A') : 'OTHER B';
          if (n == 1) await Future<void>.delayed(const Duration(seconds: 10));
        }
        final noReview = thisMode == 'empty' || r.uri.path.contains('/personal/');
        r.response.write(jsonEncode({'meta': noReview ? null : review(label)}));
      }
    } else {
      r.response.statusCode = 404;
      r.response.write('{}');
    }
    await r.response.close();
  });
  final api = ApiClient(retryDelay: const Duration(milliseconds: 20))
    ..setConnection(Connection('http://127.0.0.1:${server.port}', 'fixture-only'));
  app = AppState(api: api, bakedEndpoint: '', bakedToken: '')
    ..connected = true
    ..libraries = const [Library(id:'review',title:'Fixture Review',readOnly:true),
                         Library(id:'personal',title:'Fixture Personal',readOnly:true)];
  runApp(MaterialApp(theme: buildAppTheme(), home: Builder(builder: (context) => Scaffold(
    appBar: AppBar(title: const Text('Issue 113 safe fixture')),
    body: Column(children: [
      for (final m in ['review', 'failure', 'empty', 'personal', 'race'])
        ElevatedButton(onPressed: () {
          mode = m;
          calls = 0;
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => ViewerScreen(
            app: app, lib: m == 'personal' ? 'personal' : 'review',
            items: [
              const MediaItem(key:'a.txt',type:'other',url:'http://127.0.0.1/fixture',note:'Object fixture note'),
              if (m == 'race') const MediaItem(key:'b.txt',type:'other',url:'http://127.0.0.1/fixture'),
            ],
          )));
        }, child: Text(m)),
    ]),
  ))));
}
