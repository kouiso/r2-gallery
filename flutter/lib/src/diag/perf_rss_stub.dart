/// Web 等 dart:io の無い環境では RSS は取れない（PerfLog は null を出す）。
int? currentRssMiB() => null;
