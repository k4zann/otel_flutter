import 'dart:typed_data';

/// ParentBased(TraceIdRatioBased) sampling.
///
/// Children follow the parent's decision so traces are never half-sampled.
/// Root spans are sampled when the 56 random low bits of the trace id fall
/// under the ratio, which is deterministic per trace (W3C Level 2 randomness).
final class Sampler {
  Sampler(double ratio) : ratio = ratio.clamp(0.0, 1.0).toDouble();

  final double ratio;

  static const double _two56 = 72057594037927936.0; // 2^56

  bool shouldSample(Uint8List traceId, {bool? parentSampled}) {
    if (parentSampled != null) return parentSampled;
    if (ratio >= 1.0) return true;
    if (ratio <= 0.0) return false;
    var randomness = 0.0;
    for (var i = 9; i < 16; i++) {
      randomness = randomness * 256 + traceId[i];
    }
    // Keep when randomness >= threshold, i.e. with probability [ratio].
    return randomness >= (1.0 - ratio) * _two56;
  }
}
