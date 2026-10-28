/// 画像レビュー（AI講評）の結果。worker の GET /v1/:lib/meta が返す。KMP版 ReviewMeta と対応。
library;

class ReviewCriterion {
  final String key;
  final double? panelScore;
  final double? directorScore;
  final bool veto;
  final String? comment;
  const ReviewCriterion({
    required this.key,
    this.panelScore,
    this.directorScore,
    this.veto = false,
    this.comment,
  });

  factory ReviewCriterion.fromJson(Map<String, dynamic> j) => ReviewCriterion(
        key: (j['key'] as String?) ?? '',
        panelScore: (j['panelScore'] as num?)?.toDouble(),
        directorScore: (j['directorScore'] as num?)?.toDouble(),
        veto: (j['veto'] as bool?) ?? false,
        comment: j['comment'] as String?,
      );
}

class ReviewMeta {
  final String verdict;
  final int round;
  final String label;
  final String? intentComment;
  final double? directorScore;
  final String? directorComment;
  final List<ReviewCriterion> criteria;
  const ReviewMeta({
    required this.verdict,
    required this.round,
    required this.label,
    this.intentComment,
    this.directorScore,
    this.directorComment,
    this.criteria = const [],
  });

  factory ReviewMeta.fromJson(Map<String, dynamic> j) => ReviewMeta(
        verdict: (j['verdict'] as String?) ?? '',
        round: (j['round'] as num?)?.toInt() ?? 0,
        label: (j['label'] as String?) ?? '',
        intentComment: j['intentComment'] as String?,
        directorScore: (j['directorScore'] as num?)?.toDouble(),
        directorComment: j['directorComment'] as String?,
        criteria: [
          for (final c in (j['criteria'] as List?) ?? const [])
            if (c is Map<String, dynamic>) ReviewCriterion.fromJson(c),
        ],
      );
}
