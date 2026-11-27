import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/models.dart';
import 'transfer_api.dart';

/// multipart を続きから送る。確定したパートのたびに [onCheckpoint] を待ってから次へ進む。
/// 通常のアップロードとブラウザ取り込みの両方のキューが使う（送り方を二重に持たないため）。
///
/// [uploadId] が null なら作り、[onCheckpoint] を待ってから送る。あれば [parts] の続きから送る。
/// 続きの送信が 409 でも 400 未満でも [StoredObjectMismatch] でもない [ApiError] で失敗したら、サーバー側で失効しているので
/// [abortStale]（無ければ multipartAbort）で閉じてから作り直して最初から送る。409 は呼び手へ投げる。
/// [verifySize] なら完了の受け取りで保存された大きさを確かめる（putFile と同じ確かめ方）。
Future<void> sendMultipart({
  required TransferApi api,
  required String lib,
  required String key,
  required String mime,
  required int size,
  required int partSize,
  required Future<Uint8List> Function(int offset, int length) read,
  required String? uploadId,
  required List<UploadPart> parts,
  required Future<void> Function(String uploadId, List<UploadPart> parts)
      onCheckpoint,
  required void Function(int loaded) onProgress,
  required CancelToken cancelToken,
  Future<void> Function(String uploadId)? abortStale,
  bool verifySize = false,
}) async {
  final expectedSize = verifySize ? size : null;
  if (uploadId != null) {
    try {
      await _sendParts(api, lib, key, size, partSize, read, uploadId, parts,
          onCheckpoint, onProgress, cancelToken, expectedSize);
      return;
    } on ApiError catch (e) {
      if (e.status == 409 || e.status < 400) rethrow;
      // 完了の受け取りが合わないのは失効ではない。閉じて作り直すと完了済みの物を重複させる
      if (e is StoredObjectMismatch) rethrow;
      if (abortStale != null) {
        await abortStale(uploadId);
      } else {
        try {
          await api.multipartAbort(lib, key, uploadId);
        } on ApiError catch (e) {
          debugPrint('stale multipart not aborted: $e');
        }
      }
    }
  }
  _checkCancelled(cancelToken);
  final id = await api.multipartCreate(lib, key, mime);
  // uploadId の確定は区切り。残さんと再開時に2つ目のセッションを作り、1つ目がサーバーに残る
  await onCheckpoint(id, <UploadPart>[]);
  await _sendParts(api, lib, key, size, partSize, read, id, const [],
      onCheckpoint, onProgress, cancelToken, expectedSize);
}

Future<void> _sendParts(
  TransferApi api,
  String lib,
  String key,
  int size,
  int partSize,
  Future<Uint8List> Function(int offset, int length) read,
  String uploadId,
  List<UploadPart> confirmedParts,
  Future<void> Function(String uploadId, List<UploadPart> parts) onCheckpoint,
  void Function(int loaded) onProgress,
  CancelToken token,
  int? expectedSize,
) async {
  var parts = [...confirmedParts];
  int confirmedBytes() {
    final v = parts.length * partSize;
    return v > size ? size : v;
  }

  final total = (size + partSize - 1) ~/ partSize;
  for (var n = 1; n <= total; n++) {
    _checkCancelled(token);
    if (parts.any((p) => p.partNumber == n)) continue;
    final offset = (n - 1) * partSize;
    final len = offset + partSize > size ? size - offset : partSize;
    final chunk = await read(offset, len);
    final confirmed = confirmedBytes();
    final part = await api.putPart(lib, key, uploadId, n, chunk,
        cancelToken: token, onProgress: (s) {
      final v = confirmed + s;
      onProgress(v > size ? size : v);
    });
    // 確定したパートは止めても残す。再開ではここから先だけ送る
    parts = [...parts.where((p) => p.partNumber != part.partNumber), part];
    await onCheckpoint(uploadId, parts);
  }
  _checkCancelled(token);
  final sorted = [...parts]..sort((a, b) => a.partNumber.compareTo(b.partNumber));
  await api.multipartComplete(lib, key, uploadId, sorted,
      expectedSize: expectedSize);
}

void _checkCancelled(CancelToken token) {
  if (token.isCancelled) {
    throw DioException.requestCancelled(
        requestOptions: RequestOptions(), reason: 'cancelled');
  }
}
