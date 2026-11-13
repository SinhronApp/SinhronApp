// Where the time goes between "answered" and hearing each other (owner,
// 2026-10-18: "the call is accepted, but we hear each other only after
// 1–3 seconds"). The call marks each step against the moment it was
// answered; the diagnostics panel shows the line ("setup: …") and the log
// gets it once the other side's sound arrives (`[call-timing] …`).
//
// Steps, in the order they usually land:
//   prep   — join token + TURN credentials ready (0 when fetched while
//            ringing)
//   accept — the server has my answer (the callee; joining runs alongside)
//   room   — joined the LiveKit room (0 when the caller joined while ringing)
//   mic    — my microphone is being sent
//   sound  — the other side's sound arrives

/// One call's setup marks, in milliseconds after it was answered.
class CallTimeline {
  CallTimeline({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  DateTime? _t0;
  final _marks = <String, int>{};

  /// The call was answered: marks count from now (earlier ones are dropped).
  void start() {
    _t0 = _clock();
    _marks.clear();
  }

  bool get started => _t0 != null;

  /// [step] happened now — only its first time counts. Before [start] it
  /// is ignored (a step done while ringing is marked 0 once answered).
  void mark(String step) {
    final t0 = _t0;
    if (t0 == null) return;
    _marks.putIfAbsent(step, () => _clock().difference(t0).inMilliseconds);
  }

  /// Milliseconds from the answer to [step], or null.
  int? at(String step) => _marks[step];

  /// "prep 0 ms · room 412 ms · mic 530 ms · sound 790 ms"; empty before any.
  String get line => [for (final e in _marks.entries) '${e.key} ${e.value} ms'].join(' · ');
}
