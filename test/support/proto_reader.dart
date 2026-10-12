import 'dart:convert';
import 'dart:typed_data';

/// Independent protobuf wire-format reader used to check what the encoder
/// produced. Field values are kept raw: varints as int, LEN as bytes,
/// fixed64/fixed32 as their 8/4 bytes.
final class Msg {
  Msg.parse(Uint8List bytes) {
    var i = 0;
    int varint() {
      var result = 0;
      var shift = 0;
      while (true) {
        final b = bytes[i++];
        result |= (b & 0x7F) << shift;
        if (b < 0x80) return result;
        shift += 7;
      }
    }

    while (i < bytes.length) {
      final tag = varint();
      final field = tag >> 3;
      final type = tag & 7;
      final Object value;
      switch (type) {
        case 0:
          value = varint();
        case 1:
          value = Uint8List.sublistView(bytes, i, i + 8);
          i += 8;
        case 2:
          final len = varint();
          value = Uint8List.sublistView(bytes, i, i + len);
          i += len;
        case 5:
          value = Uint8List.sublistView(bytes, i, i + 4);
          i += 4;
        default:
          throw FormatException('wire type $type at $i');
      }
      (fields[field] ??= []).add((type, value));
    }
    if (i != bytes.length) throw const FormatException('trailing bytes');
  }

  final Map<int, List<(int, Object)>> fields = {};

  bool has(int field) => fields.containsKey(field);
  int count(int field) => fields[field]?.length ?? 0;

  Object _one(int field) {
    final list = fields[field];
    if (list == null || list.isEmpty) throw StateError('no field $field');
    return list.single.$2;
  }

  int varint(int field) => _one(field) as int;
  bool boolean(int field) => varint(field) != 0;
  Uint8List bytes(int field) => _one(field) as Uint8List;
  String string(int field) => utf8.decode(bytes(field));
  Msg message(int field) => Msg.parse(bytes(field));
  List<Msg> messages(int field) => [
        for (final (_, v) in fields[field] ?? const <(int, Object)>[])
          Msg.parse(v as Uint8List),
      ];

  int fixed32(int field) =>
      ByteData.sublistView(bytes(field)).getUint32(0, Endian.little);
  int fixed64(int field) =>
      ByteData.sublistView(bytes(field)).getUint64(0, Endian.little);
  int sfixed64(int field) =>
      ByteData.sublistView(bytes(field)).getInt64(0, Endian.little);
  double float64(int field) =>
      ByteData.sublistView(bytes(field)).getFloat64(0, Endian.little);

  List<int> packedFixed64(int field) {
    final b = ByteData.sublistView(bytes(field));
    return [
      for (var o = 0; o < b.lengthInBytes; o += 8) b.getUint64(o, Endian.little),
    ];
  }

  List<double> packedDouble(int field) {
    final b = ByteData.sublistView(bytes(field));
    return [
      for (var o = 0; o < b.lengthInBytes; o += 8)
        b.getFloat64(o, Endian.little),
    ];
  }

  /// Decodes `repeated KeyValue` into a map.
  Map<String, Object?> attributes(int field) => {
        for (final kv in messages(field))
          kv.string(1): kv.has(2) ? anyValue(kv.message(2)) : null,
      };

  /// Decodes an AnyValue message.
  static Object? anyValue(Msg v) {
    if (v.has(1)) return v.string(1);
    if (v.has(2)) return v.boolean(2);
    if (v.has(3)) return v.varint(3);
    if (v.has(4)) return v.float64(4);
    if (v.has(5)) {
      return [for (final item in v.message(5).messages(1)) anyValue(item)];
    }
    if (v.has(6)) return v.message(6).attributes(1);
    if (v.has(7)) return v.bytes(7);
    return null;
  }
}
