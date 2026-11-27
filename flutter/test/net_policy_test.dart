import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/transfer/net_state.dart';
import 'package:r2_gallery/src/transfer/transfer_platform.dart';

void main() {
  group('NetState', () {
    test('NetState.fromEvent は bool と Map を読む', () {
      expect(NetState.fromEvent(true), NetState.unknownOnline);
      expect(NetState.fromEvent(false), NetState.offline);
      expect(
        NetState.fromEvent(<Object?, Object?>{
          'online': true,
          'wifi': false,
          'metered': true,
          'dataSaver': true,
        }),
        const NetState(online: true, wifi: false, metered: true, dataSaver: true),
      );
      expect(
        NetState.fromEvent(<Object?, Object?>{
          'online': false,
          'wifi': false,
          'metered': false,
          'dataSaver': false,
        }),
        NetState.offline,
      );
      expect(NetState.fromEvent('x'), isNull);
      expect(NetState.fromEvent(null), isNull);
      expect(NetState.fromEvent(1), isNull);
    });

    test('Map の欄が欠けたり型が違ったりしてもオフラインにしない', () {
      expect(NetState.fromEvent(<Object?, Object?>{}), NetState.unknownOnline);
      expect(
        NetState.fromEvent(<Object?, Object?>{'online': 'yes', 'wifi': 1}),
        NetState.unknownOnline,
      );
      expect(
        NetState.fromEvent(<Object?, Object?>{'online': true, 'wifi': false}),
        const NetState(online: true, wifi: false, metered: false, dataSaver: false),
      );
    });

    test('端末の知らせの読めない値は unknownOnline にし、続けて同じ様子は流さない', () async {
      const mobile = <Object?, Object?>{'online': true, 'wifi': false, 'metered': true, 'dataSaver': false};
      final got = await netStatesOf(Stream<Object?>.fromIterable(
              [false, 'garbage', false, null, mobile, mobile, true]))
          .toList();
      expect(got, [
        NetState.offline,
        NetState.unknownOnline,
        NetState.offline,
        NetState.unknownOnline,
        const NetState(online: true, wifi: false, metered: true, dataSaver: false),
        NetState.unknownOnline,
      ]);
    });
  });
}
