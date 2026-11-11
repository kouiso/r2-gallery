import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/api/client.dart';
import 'package:r2_gallery/src/api/models.dart';
import 'package:r2_gallery/src/api/review_meta.dart';
import 'package:r2_gallery/src/playback/mobile_playback.dart';
import 'package:r2_gallery/src/playback/playback_session.dart';
import 'package:r2_gallery/src/state/app_state.dart';
import 'package:r2_gallery/src/ui/app_lock_layer.dart';
import 'package:r2_gallery/src/ui/viewer_screen.dart';

import 'support/fake_playback.dart';
import 'support/fake_video.dart';

const _clip = MediaItem(
  key: 'clip.mp4',
  type: 'video',
  url: 'https://fixture.invalid/m/lib/clip.mp4?e=9999999999&s=fixture',
);

class _Trace {
  _Trace(this.now) : start = now();
  final DateTime Function() now;
  final DateTime start;
  final events = <Map<String, Object>>[];
  int? played;
  int get ms => now().difference(start).inMilliseconds;
  void mark(String name, [Map<String, Object> fields = const {}]) =>
      events.add({'event': name, 'ms': ms, ...fields});
}

/// 1つの資源を順番に使う場合と、競合しない対照条件を同じ入力で比べる。実HTTPではない。
class _Transport {
  _Transport(this.trace, this.contended);
  final _Trace trace;
  final bool contended;
  Future<void> _tail = Future.value();
  final bytes = List<int>.generate(256 * 1024, (i) => i % 251);
  int rangeRequests = 0;
  Future<void> request(String name, Duration latency) {
    trace.mark('${name}_requested');
    final ready = contended ? _tail : Future<void>.value();
    final response = ready.then((_) async {
      trace.mark('${name}_started');
      await Future<void>.delayed(latency);
      trace.mark('${name}_completed');
    });
    if (contended) _tail = response;
    return response;
  }

  Future<List<int>> range() async {
    rangeRequests++;
    await request('range_mock', const Duration(milliseconds: 300));
    return bytes.sublist(0, 4096);
  }
}

class _Api extends ApiClient {
  _Api(this.transport);
  final _Transport transport;
  int reviews = 0;
  int folders = 0;
  int downloads = 0;
  @override
  Future<ReviewMeta?> meta(String libId, String key) async {
    reviews++;
    await transport.request('review', const Duration(milliseconds: 240));
    return const ReviewMeta(verdict: 'pass', round: 1, label: 'fixture');
  }

  @override
  Future<FolderPage> folder(
    String libId, {
    String prefix = '',
    String? cursor,
    bool recursive = false,
  }) async {
    folders++;
    throw StateError('Startup must use the URL already in the list');
  }

  @override
  Future<void> downloadToFile(String url, String path) async {
    downloads++;
    throw StateError('Network playback must not wait for a complete download');
  }
}

class _App extends AppState {
  _App(_Api api) : super(api: api, bakedEndpoint: '', bakedToken: '');
  @override
  bool get offlineSupported => false;
}

class _Port extends FakePlaybackPort {
  _Port(this.trace);
  final _Trace trace;
  @override
  Future<void> bind(PlaybackSession session) async {
    trace.mark('system_bind_mock_started');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await super.bind(session);
    trace.mark('system_bind_mock_completed');
  }

  @override
  Future<bool> activateAudio(bool active) async {
    if (active) {
      trace.mark('focus_mock_started');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      trace.mark('focus_mock_completed');
    }
    return super.activateAudio(active);
  }
}

class _Video extends FakeVideo {
  _Video(this.transport, this.trace);
  final _Transport transport;
  final _Trace trace;
  int initializes = 0;
  @override
  Future<void> initialize() async {
    initializes++;
    trace.mark('controller_initialize_started');
    final bytes = await transport.range();
    expect(bytes.length, 4096);
    trace.mark('container_metadata_mock_ready', {'bytes': bytes.length});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await super.initialize();
    trace.mark('controller_initialize_completed');
  }

  @override
  Future<void> play() async {
    await super.play();
    trace.played ??= trace.ms;
    trace.mark('play_request_accepted_mock');
  }
}

void main() {
  for (final contended in [false, true]) {
    testWidgets('同じ遅延注入で初回playまでの経路を記録 resourceContended=$contended', (
      tester,
    ) async {
      final original = MobilePlayback.coordinator;
      addTearDown(() => MobilePlayback.coordinator = original);
      final samples = <Map<String, Object?>>[];
      for (var sample = 0; sample < 3; sample++) {
        final trace = _Trace(tester.binding.clock.now);
        final transport = _Transport(trace, contended);
        final api = _Api(transport)
          ..setConnection(
            const Connection('https://fixture.invalid', 'synthetic'),
          );
        final app = _App(api)
          ..connected = true
          ..loading = false
          ..activeLib = 'lib'
          ..libraries = const [Library(id: 'lib', title: 'fixture')];
        final owner = PlaybackCoordinator(_Port(trace));
        MobilePlayback.coordinator = owner;
        final video = _Video(transport, trace);
        var sources = 0;
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => AppLockScope(app: app, child: child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => unawaited(
                    openViewer(
                      context,
                      app: app,
                      lib: 'lib',
                      items: const [_clip],
                      index: 0,
                      videoFactory: (url) {
                        sources++;
                        expect(url, _clip.url);
                        trace.mark('listed_url_passed_to_controller');
                        return video;
                      },
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        trace.mark('open_play_action');
        await tester.tap(find.text('open'));
        await tester.pump();
        for (var i = 0; i < 150 && trace.played == null; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(video.value.isPlaying, isTrue);
        expect(sources, 1);
        expect(video.initializes, 1);
        expect(transport.rangeRequests, 1);
        expect(api.folders, 0);
        expect(api.downloads, 0);
        samples.add({
          'sample': sample,
          'play_accepted_mock_ms': trace.played,
          'review_requests_before_play': api.reviews,
          'range_requests_mock': transport.rangeRequests,
          'range_bytes_mock': 4096,
          'fixture_total_bytes': transport.bytes.length,
          'extra_url_requests': api.folders,
          'whole_file_downloads': api.downloads,
          'first_frame_ms': null,
          'events': trace.events,
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(video.disposed, isTrue);
        app.dispose();
      }
      const dir = String.fromEnvironment('STARTUP_EVIDENCE_DIR');
      const variant = String.fromEnvironment(
        'STARTUP_EVIDENCE_VARIANT',
        defaultValue: 'unspecified',
      );
      if (dir.isNotEmpty) {
        await tester.runAsync(() async {
          final file = File(
            '$dir/$variant-${contended ? 'contended' : 'independent'}.json',
          );
          await file.parent.create(recursive: true);
          await file.writeAsString(
            const JsonEncoder.withIndent('  ').convert({
              'variant': variant,
              'resource_contended': contended,
              'scope':
                  'Virtual-clock delay injection; transport/controller/OS bridge are mocks, no native decode or first frame',
              'injected_ms': {
                'review': 240,
                'range': 300,
                'decoder': 60,
                'bind': 40,
                'focus': 10,
              },
              'samples': samples,
            }),
          );
        });
      }
    });
  }
}
