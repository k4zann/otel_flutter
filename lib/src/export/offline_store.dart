import 'dart:typed_data';

import 'package:meta/meta.dart';

/// The three OTLP signals and their HTTP paths.
enum Signal {
  traces,
  metrics,
  logs;

  String get path => 'v1/$name';
}

/// An encoded export request, exactly as it goes on the wire.
@internal
final class Payload {
  Payload(this.signal, this.bytes, {required this.gzipped});
  final Signal signal;
  final Uint8List bytes;
  final bool gzipped;
}

/// Disk queue for requests that could not be sent (offline, server down).
///
/// Files are sent oldest-first once the network is back, and survive the app
/// being killed. Size and age are capped so the queue can't fill the device.
@internal
abstract interface class OfflineStore {
  Future<void> save(Payload payload);

  /// The oldest stored payload, or null when the queue is empty.
  Future<StoredPayload?> oldest();

  Future<void> delete(StoredPayload stored);
}

@internal
final class StoredPayload {
  StoredPayload(this.payload, this.handle);
  final Payload payload;
  final Object handle;
}
