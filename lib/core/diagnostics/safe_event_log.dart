import 'dart:collection';

/// A small, in-memory ring buffer of the secret-free breadcrumbs
/// [StabilityDiagnostics] emits (lifecycle transitions, playback-output
/// handoffs, pre-cache decisions, and playback-error kinds).
///
/// It exists so the "Report a bug" flow can optionally include the last few app
/// events even in a release build, where [StabilityDiagnostics]'s
/// `developer.log` output is silent. Nothing here is ever sent anywhere on its
/// own: events are held only in memory, capped at [capacity], cleared when the
/// process ends, and surfaced solely when the user explicitly builds a bug
/// report and leaves the "recent app events" toggle on.
///
/// Secret-free by construction: an event carries only a fixed
/// [SafeEvent.category] and a structural [SafeEvent.detail] (an enum name or a
/// fixed label like `skip:disabled`) handed in by [StabilityDiagnostics]. There
/// is no field for a token, password, authenticated URL, track title, or local
/// path, so nothing sensitive can be recorded here in the first place.
class SafeEventLog {
  SafeEventLog({this.capacity = 50}) : assert(capacity > 0);

  /// The most events retained. Older events roll off once this is exceeded, so
  /// the buffer stays bounded over a long session.
  final int capacity;

  final ListQueue<SafeEvent> _events = ListQueue<SafeEvent>();

  /// Records one breadcrumb, dropping the oldest entry once [capacity] is
  /// exceeded.
  void record(String category, String detail) {
    _events.addLast(SafeEvent(category, detail));
    while (_events.length > capacity) {
      _events.removeFirst();
    }
  }

  /// The retained events, oldest first.
  List<SafeEvent> get events => List<SafeEvent>.unmodifiable(_events);

  /// The retained events rendered one per line (`category: detail`), oldest
  /// first — the form the bug report embeds.
  List<String> get lines =>
      _events.map((SafeEvent event) => event.line).toList(growable: false);

  bool get isEmpty => _events.isEmpty;

  bool get isNotEmpty => _events.isNotEmpty;

  /// Clears all retained events.
  void clear() => _events.clear();

  /// The process-wide log [StabilityDiagnostics] writes to and the bug report
  /// reads from. A single shared instance mirrors the static, plugin-free style
  /// of the diagnostics utilities that feed it.
  static final SafeEventLog instance = SafeEventLog();
}

/// One secret-free breadcrumb: a fixed [category] and a structural [detail].
class SafeEvent {
  const SafeEvent(this.category, this.detail);

  /// The kind of event — e.g. `lifecycle`, `output`, `precache`, `error`.
  final String category;

  /// The structural detail: an enum name or fixed label (e.g. `resumed`,
  /// `cast`, `skip:disabled`, `load`). Never free text or a secret.
  final String detail;

  /// The one-line form embedded in a report: `category: detail`.
  String get line => '$category: $detail';
}
