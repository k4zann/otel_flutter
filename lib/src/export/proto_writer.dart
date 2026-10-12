import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Minimal protobuf wire-format writer.
///
/// Writes straight into one growable buffer: no generated classes and no
/// intermediate object graph. Nested messages reserve one length byte and are
/// shifted only in the rare case the body reaches 128 bytes.
///
/// All arithmetic stays below 2^53, so it is also exact when compiled to
/// JavaScript, where bitwise operators are 32-bit.
@internal
final class ProtoWriter {
  ProtoWriter([int initialCapacity = 16384])
    : _buf = Uint8List(initialCapacity) {
    _view = ByteData.view(_buf.buffer);
  }

  Uint8List _buf;
  late ByteData _view;
  int _len = 0;

  static const int _varintType = 0;
  static const int _fixed64Type = 1;
  static const int _lenType = 2;
  static const int _fixed32Type = 5;

  static const int _two32 = 0x100000000;

  int get length => _len;

  /// Copy of the bytes written so far.
  Uint8List toBytes() => _buf.sublist(0, _len);

  void _ensure(int extra) {
    final need = _len + extra;
    if (need <= _buf.length) return;
    var capacity = _buf.length * 2;
    while (capacity < need) {
      capacity *= 2;
    }
    _buf = Uint8List(capacity)..setRange(0, _len, _buf);
    _view = ByteData.view(_buf.buffer);
  }

  void _tag(int field, int wireType) => _varint(field * 8 + wireType);

  void _varint(int v) {
    if (v < 0) {
      final (hi, lo) = _twosComplement(v);
      _varintHiLo(hi, lo);
      return;
    }
    _ensure(10);
    while (v >= 0x80) {
      _buf[_len++] = (v % 0x80) + 0x80;
      v = v ~/ 0x80;
    }
    _buf[_len++] = v;
  }

  /// Varint of the unsigned 64-bit value hi * 2^32 + lo.
  void _varintHiLo(int hi, int lo) {
    _ensure(10);
    while (hi != 0 || lo >= 0x80) {
      _buf[_len++] = (lo % 0x80) + 0x80;
      lo = lo ~/ 0x80 + (hi % 0x80) * 0x2000000; // 2^25
      hi = hi ~/ 0x80;
    }
    _buf[_len++] = lo;
  }

  /// Unsigned 32-bit halves of the 64-bit two's complement of negative [v].
  static (int, int) _twosComplement(int v) {
    final abs = -v;
    final absLo = abs % _two32;
    final absHi = abs ~/ _two32;
    var lo = _two32 - absLo;
    var hi = 0xFFFFFFFF - absHi;
    if (lo == _two32) {
      lo = 0;
      hi += 1;
    }
    return (hi % _two32, lo);
  }

  void _fixed64HiLo(int hi, int lo) {
    _ensure(8);
    _view
      ..setUint32(_len, lo, Endian.little)
      ..setUint32(_len + 4, hi, Endian.little);
    _len += 8;
  }

  // ---- Raw values (used inside packed repeated fields) ----

  void fixed64Raw(int v) {
    if (v >= 0) {
      _fixed64HiLo(v ~/ _two32, v % _two32);
    } else {
      final (hi, lo) = _twosComplement(v);
      _fixed64HiLo(hi, lo);
    }
  }

  void doubleRaw(double v) {
    _ensure(8);
    _view.setFloat64(_len, v, Endian.little);
    _len += 8;
  }

  // ---- Fields ----

  void varintField(int field, int v) {
    _tag(field, _varintType);
    _varint(v);
  }

  void boolField(int field, bool v) => varintField(field, v ? 1 : 0);

  void fixed32Field(int field, int v) {
    _tag(field, _fixed32Type);
    _ensure(4);
    _view.setUint32(_len, v, Endian.little);
    _len += 4;
  }

  void fixed64Field(int field, int v) {
    _tag(field, _fixed64Type);
    fixed64Raw(v);
  }

  /// sfixed64 shares fixed64's encoding (two's complement, little endian).
  void sfixed64Field(int field, int v) => fixed64Field(field, v);

  /// fixed64 nanoseconds from microseconds without exceeding 2^53.
  void timeField(int field, int micros) {
    _tag(field, _fixed64Type);
    final hiMicros = micros ~/ _two32;
    final loNanos = (micros % _two32) * 1000; // < 2^42
    _fixed64HiLo(hiMicros * 1000 + loNanos ~/ _two32, loNanos % _two32);
  }

  void doubleField(int field, double v) {
    _tag(field, _fixed64Type);
    doubleRaw(v);
  }

  void stringField(int field, String s) {
    _tag(field, _lenType);
    final n = s.length;
    var ascii = true;
    for (var i = 0; i < n; i++) {
      if (s.codeUnitAt(i) >= 0x80) {
        ascii = false;
        break;
      }
    }
    if (ascii) {
      _varint(n);
      _ensure(n);
      for (var i = 0; i < n; i++) {
        _buf[_len++] = s.codeUnitAt(i);
      }
    } else {
      _writeLengthPrefixed(utf8.encode(s));
    }
  }

  void bytesField(int field, Uint8List bytes) {
    _tag(field, _lenType);
    _writeLengthPrefixed(bytes);
  }

  /// Embeds an already-encoded message body.
  void messageBytesField(int field, Uint8List body) => bytesField(field, body);

  void _writeLengthPrefixed(Uint8List bytes) {
    _varint(bytes.length);
    _ensure(bytes.length);
    _buf.setRange(_len, _len + bytes.length, bytes);
    _len += bytes.length;
  }

  /// Starts a nested message (or packed field); pass the result to [end].
  int begin(int field) {
    _tag(field, _lenType);
    _ensure(1);
    return _len++;
  }

  void end(int start) {
    final bodyLength = _len - start - 1;
    if (bodyLength < 0x80) {
      _buf[start] = bodyLength;
      return;
    }
    var size = 1;
    for (var v = bodyLength; v >= 0x80; v = v ~/ 0x80) {
      size++;
    }
    final shift = size - 1;
    _ensure(shift);
    _buf.setRange(start + 1 + shift, _len + shift, _buf, start + 1);
    _len += shift;
    var p = start;
    var v = bodyLength;
    while (v >= 0x80) {
      _buf[p++] = (v % 0x80) + 0x80;
      v = v ~/ 0x80;
    }
    _buf[p] = v;
  }
}
