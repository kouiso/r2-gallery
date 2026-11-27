import 'package:flutter_test/flutter_test.dart';
import 'package:r2_gallery/src/transfer/net_policy.dart';
import 'package:r2_gallery/src/transfer/net_state.dart';
import 'package:r2_gallery/src/transfer/transfer_platform.dart';
import 'package:r2_gallery/src/transfer/transfer_rows.dart';

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
  group('transferWait', () {
    const mobile =
        NetState(online: true, wifi: false, metered: true, dataSaver: false);
    const wifi =
        NetState(online: true, wifi: true, metered: false, dataSaver: false);

    test('Wi‑Fi 限定のアップロードはモバイル回線で待つ', () {
      expect(
        transferWait(mobile, const TransferNetPolicy(uploadWifiOnly: true),
            TransferLeg.upload,
            foreground: true),
        NetWait.wifi,
      );
      // Wi‑Fi に着けば動く
      expect(
        transferWait(wifi, const TransferNetPolicy(uploadWifiOnly: true),
            TransferLeg.upload,
            foreground: true),
        isNull,
      );
    });

    test('設定が無ければモバイル回線でも動く', () {
      for (final leg in TransferLeg.values) {
        expect(
            transferWait(mobile, const TransferNetPolicy(), leg, foreground: true),
            isNull);
      }
    });

    test('ダウンロードの設定はアップロードに効かない', () {
      const p = TransferNetPolicy(downloadWifiOnly: true);
      expect(transferWait(mobile, p, TransferLeg.upload, foreground: true),
          isNull);
      expect(transferWait(mobile, p, TransferLeg.download, foreground: true),
          NetWait.wifi);
    });

    test('従量制の Wi‑Fi は Wi‑Fi として扱う', () {
      const meteredWifi =
          NetState(online: true, wifi: true, metered: true, dataSaver: false);
      const p = TransferNetPolicy(uploadWifiOnly: true, downloadWifiOnly: true);
      for (final leg in TransferLeg.values) {
        expect(transferWait(meteredWifi, p, leg, foreground: true), isNull);
      }
    });

    test('省データで従量制、裏にいる時は待つ', () {
      const saver =
          NetState(online: true, wifi: false, metered: true, dataSaver: true);
      // 設定に関係なく待つ。前面に戻れば動く
      expect(
        transferWait(saver, const TransferNetPolicy(), TransferLeg.upload,
            foreground: false),
        NetWait.dataSaver,
      );
      expect(
        transferWait(saver, const TransferNetPolicy(), TransferLeg.upload,
            foreground: true),
        isNull,
      );
      // 従量制でなければ（Wi‑Fi の省データ設定は OS が裏の通信を止めない）待たない
      const unmetered =
          NetState(online: true, wifi: true, metered: false, dataSaver: true);
      expect(
        transferWait(unmetered, const TransferNetPolicy(), TransferLeg.download,
            foreground: false),
        isNull,
      );
    });

    test('オフラインはどの設定でも待つ。理由は Wi‑Fi より先にオフライン', () {
      expect(
        transferWait(NetState.offline, const TransferNetPolicy(uploadWifiOnly: true),
            TransferLeg.upload,
            foreground: true),
        NetWait.offline,
      );
    });

    test('Wi‑Fi かが分からない古い端末側は Wi‑Fi 限定の行も待たせない', () {
      const p = TransferNetPolicy(uploadWifiOnly: true, downloadWifiOnly: true);
      for (final leg in TransferLeg.values) {
        expect(transferWait(NetState.unknownOnline, p, leg, foreground: false),
            isNull);
      }
    });

    test('netWaitLabel は理由ごとの文言を返し、null は null', () {
      expect(netWaitLabel(null), isNull);
      expect(netWaitLabel(NetWait.offline), '待機中（オフライン）');
      expect(netWaitLabel(NetWait.wifi), 'Wi‑Fi接続待ち');
      expect(netWaitLabel(NetWait.dataSaver), '省データ設定のため待機中');
    });
  });
}
