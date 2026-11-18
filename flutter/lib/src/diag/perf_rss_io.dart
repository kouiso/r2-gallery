import 'dart:io';

int? currentRssMiB() => (ProcessInfo.currentRss / (1024 * 1024)).round();
