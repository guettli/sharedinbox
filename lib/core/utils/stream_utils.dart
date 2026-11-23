import 'dart:async';

/// The latest value of [a] and of [b], combined, each time either emits
/// (once both have). Cancelling it cancels both.
Stream<R> combineLatest<A, B, R>(
  Stream<A> a,
  Stream<B> b,
  R Function(A a, B b) combine,
) {
  // Single-subscription: it ends with its listener's cancel, which cancels
  // both sources; nothing is added after that.
  // ignore: close_sinks
  late final StreamController<R> out;
  StreamSubscription<A>? subA;
  StreamSubscription<B>? subB;
  late A lastA;
  late B lastB;
  var hasA = false;
  var hasB = false;
  void emit() {
    if (hasA && hasB) out.add(combine(lastA, lastB));
  }

  out = StreamController<R>(
    onListen: () {
      subA = a.listen(
        (v) {
          lastA = v;
          hasA = true;
          emit();
        },
        onError: out.addError,
      );
      subB = b.listen(
        (v) {
          lastB = v;
          hasB = true;
          emit();
        },
        onError: out.addError,
      );
    },
    onPause: () {
      subA?.pause();
      subB?.pause();
    },
    onResume: () {
      subA?.resume();
      subB?.resume();
    },
    // Both at once: a source slow to cancel must not keep the other one
    // listening.
    onCancel: () => Future.wait([
      if (subA case final s?) s.cancel(),
      if (subB case final s?) s.cancel(),
    ]),
  );
  return out.stream;
}
