import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:otel_flutter/src/export/proto_writer.dart';

import 'support/proto_reader.dart';

void main() {
  Uint8List write(void Function(ProtoWriter w) fn) {
    final w = ProtoWriter(8);
    fn(w);
    return w.toBytes();
  }

  test('varints match the protobuf spec', () {
    expect(write((w) => w.varintField(1, 0)), [0x08, 0x00]);
    expect(write((w) => w.varintField(1, 127)), [0x08, 0x7F]);
    expect(write((w) => w.varintField(1, 300)), [0x08, 0xAC, 0x02]);
    // int64 -1 is ten bytes of two's complement.
    expect(write((w) => w.varintField(1, -1)),
        [0x08, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]);
  });

  test('64-bit values round-trip', () {
    const big = 0x123456789ABCDEF;
    final m = Msg.parse(write((w) => w
      ..varintField(1, big)
      ..varintField(2, -123456789012)
      ..fixed64Field(3, big)
      ..sfixed64Field(4, -42)
      ..doubleField(5, -1.5)
      ..fixed32Field(6, 0xFFFFFFFF)));
    expect(m.varint(1), big);
    expect(m.varint(2), -123456789012);
    expect(m.fixed64(3), big);
    expect(m.sfixed64(4), -42);
    expect(m.float64(5), -1.5);
    expect(m.fixed32(6), 0xFFFFFFFF);
  });

  test('timeField writes nanoseconds from microseconds', () {
    const micros = 1760000000123456; // 2025-10-09
    final m = Msg.parse(write((w) => w.timeField(1, micros)));
    expect(m.fixed64(1), micros * 1000);
  });

  test('strings: ASCII fast path and UTF-8', () {
    final m = Msg.parse(write((w) => w
      ..stringField(1, 'hello')
      ..stringField(2, 'Привет, 世界 👋')
      ..stringField(3, '')));
    expect(m.string(1), 'hello');
    expect(m.string(2), 'Привет, 世界 👋');
    expect(m.string(3), '');
  });

  test('nested messages of any size get correct length prefixes', () {
    for (final size in [0, 1, 127, 128, 300, 16383, 16384, 100000]) {
      final payload = 'x' * size;
      final bytes = write((w) {
        final outer = w.begin(1);
        final inner = w.begin(2);
        w.stringField(3, payload);
        w.end(inner);
        w.varintField(4, 7);
        w.end(outer);
        w.varintField(5, 9);
      });
      final m = Msg.parse(bytes);
      expect(m.message(1).message(2).string(3), payload, reason: 'size $size');
      expect(m.message(1).varint(4), 7);
      expect(m.varint(5), 9);
    }
  });
}
