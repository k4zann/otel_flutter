import 'dart:math';
import 'dart:typed_data';

/// Generates W3C trace and span ids.
///
/// Uses the platform CSPRNG directly. A PRNG seeded with 32 bits (the common
/// shortcut) would make ID sequences collide across devices once an app has a
/// few tens of thousands of installs.
abstract final class Ids {
  static final Random _random = Random.secure();

  static Uint8List traceId() => _nonZero(16);
  static Uint8List spanId() => _nonZero(8);

  /// Random (version 4) UUID, used for session, instance and install ids.
  static String uuidV4() {
    final b = _nonZero(16);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    final h = toHex(b);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
        '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  static Uint8List _nonZero(int length) {
    final bytes = Uint8List(length);
    while (true) {
      for (var i = 0; i < length; i += 4) {
        final word = _random.nextInt(0x100000000);
        bytes[i] = word & 0xFF;
        bytes[i + 1] = (word >> 8) & 0xFF;
        bytes[i + 2] = (word >> 16) & 0xFF;
        bytes[i + 3] = (word >> 24) & 0xFF;
      }
      if (!isAllZero(bytes)) return bytes;
    }
  }

  static bool isAllZero(Uint8List bytes) {
    for (final b in bytes) {
      if (b != 0) return false;
    }
    return true;
  }

  static const _hexChars = '0123456789abcdef';

  static String toHex(Uint8List bytes) {
    final codes = Uint8List(bytes.length * 2);
    for (var i = 0; i < bytes.length; i++) {
      codes[i * 2] = _hexChars.codeUnitAt(bytes[i] >> 4);
      codes[i * 2 + 1] = _hexChars.codeUnitAt(bytes[i] & 0x0F);
    }
    return String.fromCharCodes(codes);
  }

  /// Parses lowercase hex (as W3C Trace Context requires). Returns null for
  /// wrong length or any non-hex / uppercase character.
  static Uint8List? fromHex(String hex, int byteLength) {
    if (hex.length != byteLength * 2) return null;
    final out = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      final hi = _nibble(hex.codeUnitAt(i * 2));
      final lo = _nibble(hex.codeUnitAt(i * 2 + 1));
      if (hi < 0 || lo < 0) return null;
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  static int _nibble(int c) {
    if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
    if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10; // a-f
    return -1;
  }
}
