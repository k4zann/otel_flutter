import 'dart:typed_data';

import '../export/offline_store.dart';

/// Web: the browser provides no OS details without extra packages.
Map<String, Object> platformResourceAttributes() => const {};

/// Web: no gzip (CompressionStream would need JS interop); send raw.
Future<Uint8List?> gzipBytes(Uint8List bytes) async => null;

/// Web: no file system, so no offline queue.
OfflineStore? createOfflineStore(
  String directory, {
  required int maxBytes,
  required Duration maxAge,
}) => null;

Future<String?> loadOrCreateInstallationId(String? directory) async => null;

/// Web: no native crashes to attribute.
Future<String?> rotateCrashContext(String directory) async => null;

Future<void> writeCrashContext(String directory, String json) async {}
