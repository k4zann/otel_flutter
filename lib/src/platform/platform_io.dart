import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/diagnostics.dart';
import '../core/ids.dart';
import '../export/offline_store.dart';

/// OS details from dart:io. Device model/manufacturer need a plugin such as
/// device_info_plus; pass them via `OtelConfig.resourceAttributes`.
Map<String, Object> platformResourceAttributes() {
  final os = Platform.operatingSystem;
  return {
    'os.type': switch (os) {
      'ios' || 'macos' => 'darwin',
      'android' || 'linux' => 'linux',
      _ => os,
    },
    'os.name': switch (os) {
      'ios' => 'iOS',
      'android' => 'Android',
      'macos' => 'macOS',
      'windows' => 'Windows',
      'linux' => 'Linux',
      _ => os,
    },
    'os.version': Platform.operatingSystemVersion,
    'process.runtime.name': 'dart',
    'process.runtime.version': Platform.version.split(' ').first,
  };
}

/// Payloads above this size are gzipped on a background isolate so a large
/// batch can't cause a dropped frame.
const int _isolateThreshold = 64 * 1024;

Future<Uint8List?> gzipBytes(Uint8List bytes) async {
  if (bytes.length < _isolateThreshold) return _gzip(bytes);
  try {
    return await Isolate.run(() => _gzip(bytes));
  } catch (_) {
    return _gzip(bytes);
  }
}

Uint8List _gzip(Uint8List bytes) {
  final out = gzip.encode(bytes);
  return out is Uint8List ? out : Uint8List.fromList(out);
}

OfflineStore? createOfflineStore(
  String directory, {
  required int maxBytes,
  required Duration maxAge,
}) =>
    _FileStore(directory, maxBytes, maxAge);

Future<String?> loadOrCreateInstallationId(String? directory) async {
  if (directory == null) return null;
  try {
    final file = File('$directory/otel_flutter_installation_id');
    if (await file.exists()) {
      final id = (await file.readAsString()).trim();
      if (id.isNotEmpty) return id;
    }
    final id = Ids.uuidV4();
    await file.parent.create(recursive: true);
    await file.writeAsString(id, flush: true);
    return id;
  } catch (e) {
    Diagnostics.warnOnce('installation-id', 'Cannot store installation id: $e');
    return null;
  }
}

const String _crashContextFile = 'otel_flutter_context.json';

/// Moves the previous run's crash context to `.prev` and returns it. With
/// no current file, an older `.prev` is removed: it describes a run before
/// the previous one, and a crash must not be attributed to it.
Future<String?> rotateCrashContext(String directory) async {
  try {
    final current = File('$directory/$_crashContextFile');
    final previous = File('$directory/$_crashContextFile.prev');
    if (await current.exists()) {
      await current.rename(previous.path);
      return await previous.readAsString();
    }
    if (await previous.exists()) await previous.delete();
  } catch (e) {
    Diagnostics.warnOnce('crash-context-read', 'Cannot read crash context: $e');
  }
  return null;
}

/// Replaces the crash context atomically (temp file + rename), so a crash
/// mid-write never leaves a partial file. No fsync: a crashed process does
/// not lose data already handed to the OS, and this runs on navigation.
Future<void> writeCrashContext(String directory, String json) async {
  try {
    final tmp = File('$directory/$_crashContextFile.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(json);
    await tmp.rename('$directory/$_crashContextFile');
  } catch (e) {
    Diagnostics.warnOnce('crash-context-write', 'Cannot save crash context: $e');
  }
}

/// One file per request: `<micros>_<seq>.<signal>[.gz]`, so name order is
/// age order. Written to `.tmp` first and renamed, so a crash mid-write never
/// leaves a truncated payload behind.
final class _FileStore implements OfflineStore {
  _FileStore(String base, this._maxBytes, this._maxAge)
      : _dir = Directory('$base/otel_flutter_queue');

  final Directory _dir;
  final int _maxBytes;
  final Duration _maxAge;
  int _seq = 0;

  /// False once a scan found the queue empty; avoids listing the directory
  /// after every successful export.
  bool _maybeNonEmpty = true;

  @override
  Future<void> save(Payload payload) async {
    try {
      await _dir.create(recursive: true);
      final ts = DateTime.now().microsecondsSinceEpoch.toString().padLeft(17, '0');
      final seq = (_seq++ % 1000000).toString().padLeft(6, '0');
      final name = '${ts}_$seq.${payload.signal.name}'
          '${payload.gzipped ? '.gz' : ''}';
      final tmp = File('${_dir.path}/$name.tmp');
      await tmp.writeAsBytes(payload.bytes, flush: true);
      await tmp.rename('${_dir.path}/$name');
      _maybeNonEmpty = true;
      await _prune();
    } catch (e) {
      Diagnostics.warnOnce('store-save', 'Cannot write offline queue: $e');
    }
  }

  @override
  Future<StoredPayload?> oldest() async {
    if (!_maybeNonEmpty) return null;
    final cutoff = _cutoffMicros();
    for (final file in await _files()) {
      final parsed = _parse(file);
      if (parsed == null || parsed.$1 < cutoff) {
        await _tryDelete(file);
        continue;
      }
      try {
        final bytes = await file.readAsBytes();
        return StoredPayload(
          Payload(parsed.$2, bytes, gzipped: parsed.$3),
          file,
        );
      } catch (_) {
        await _tryDelete(file);
      }
    }
    _maybeNonEmpty = false;
    return null;
  }

  @override
  Future<void> delete(StoredPayload stored) => _tryDelete(stored.handle as File);

  int _cutoffMicros() =>
      DateTime.now().subtract(_maxAge).microsecondsSinceEpoch;

  Future<List<File>> _files() async {
    try {
      if (!await _dir.exists()) return const [];
      final files = <File>[];
      await for (final entity in _dir.list()) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.tmp')) {
          // Leftover from a crash mid-write.
          final age = DateTime.now().difference(await entity.lastModified());
          if (age > const Duration(minutes: 1)) await _tryDelete(entity);
          continue;
        }
        files.add(entity);
      }
      files.sort((a, b) => a.path.compareTo(b.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  /// Drops expired files, then the oldest ones until under the size cap.
  Future<void> _prune() async {
    final files = await _files();
    final sizes = <int>[];
    var total = 0;
    for (final f in files) {
      final size = await f.length();
      sizes.add(size);
      total += size;
    }
    final cutoff = _cutoffMicros();
    for (var i = 0; i < files.length; i++) {
      final ts = _parse(files[i])?.$1 ?? 0;
      if (ts >= cutoff && total <= _maxBytes) break;
      total -= sizes[i];
      await _tryDelete(files[i]);
    }
  }

  /// (timestamp micros, signal, gzipped) from the file name.
  static (int, Signal, bool)? _parse(File file) {
    final name = file.uri.pathSegments.last;
    final parts = name.split('.');
    if (parts.length < 2) return null;
    final ts = int.tryParse(parts[0].split('_').first);
    final signal = Signal.values.where((s) => s.name == parts[1]).firstOrNull;
    if (ts == null || signal == null) return null;
    return (ts, signal, parts.length > 2 && parts[2] == 'gz');
  }

  static Future<void> _tryDelete(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }
}
