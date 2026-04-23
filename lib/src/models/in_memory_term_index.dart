import 'dart:convert';
import 'dart:typed_data';

/// Per-language in-memory term index.
///
/// Built once per language by the search worker from a walk of the
/// language-scoped dicts in Isar (see `search_worker.dart`), this
/// structure owns the minimum data necessary to resolve the
/// `termEqualTo` / `termStartsWith` hot path of
/// `runStandardLatinSearch` entirely in memory — no Isar calls for
/// stage 1.
///
/// Storage is byte-packed to keep the per-term overhead low:
///
///   termBytes    : concatenated UTF-8 of all (lower-cased) terms
///   termOffsets  : start offsets into termBytes, length n + 1
///   entryIds     : Isar row id for term i
///   dictIds      : dict id for term i
///
/// Terms are sorted by `String.compareTo` ordering at build time.
/// `String.compareTo` compares UTF-16 code units, which agrees with
/// UTF-8 byte order for BMP characters (everything except astral-
/// plane emoji, which don't appear in dict terms). Binary search
/// decodes each candidate term back to a `String` for comparison —
/// that's ~20 allocations per exact lookup, which is dwarfed by the
/// Isar round-trip it replaces.
///
/// Memory, rough order of magnitude for ~500k terms with 10-byte
/// average UTF-8 length:
///   termBytes    ~5 MB
///   termOffsets  ~2 MB  (4 bytes × n)
///   entryIds     ~4 MB  (8 bytes × n)
///   dictIds      ~2 MB  (4 bytes × n)
///   ~13 MB per language. Scales linearly.
class InMemoryTermIndex {
  InMemoryTermIndex({
    required this.termBytes,
    required this.termOffsets,
    required this.entryIds,
    required this.dictIds,
  }) : assert(termOffsets.length == entryIds.length + 1),
       assert(dictIds.length == entryIds.length);

  /// Concatenated UTF-8 bytes of all terms. `termOffsets[i]` is the
  /// byte offset where term `i` begins; `termOffsets[i + 1]` is where
  /// it ends (exclusive).
  final Uint8List termBytes;

  /// Length `n + 1`. Final entry is `termBytes.length`.
  final Uint32List termOffsets;

  /// Length `n`. Parallel to `dictIds` and to the (term at index i).
  final Int64List entryIds;

  /// Length `n`. Parallel to `entryIds`.
  final Int32List dictIds;

  int get length => entryIds.length;

  /// Allocates a new `String` view of the term at [i]. Only used in
  /// the hot binary-search comparison path.
  String _termAt(int i) {
    final start = termOffsets[i];
    final end = termOffsets[i + 1];
    return utf8.decode(Uint8List.sublistView(termBytes, start, end));
  }

  /// First index where `_termAt(i) >= needle`. Returns `length` if
  /// every term sorts before [needle].
  int _lowerBound(String needle) {
    int lo = 0;
    int hi = length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_termAt(mid).compareTo(needle) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// All entry ids whose term equals [needle] (case-insensitive — the
  /// caller should lowercase before calling for consistency with how
  /// terms were stored at build time).
  List<int> findExact(String needle) {
    if (length == 0) return const <int>[];
    final start = _lowerBound(needle);
    if (start >= length) return const <int>[];
    final results = <int>[];
    for (int i = start; i < length; i++) {
      final t = _termAt(i);
      if (t != needle) break;
      results.add(entryIds[i]);
    }
    return results;
  }

  /// All entry ids whose term starts with [prefix], up to [limit] of
  /// them. Walks the sorted list forward from the first match. Terms
  /// are ordered shortest-first within a prefix bucket by their
  /// byte-length tie-break in the UTF-8 ordering, so a small [limit]
  /// gives a reasonable cross-section rather than an adversarial
  /// subset.
  List<int> findStartsWith(String prefix, {int limit = 32}) {
    if (length == 0 || prefix.isEmpty) return const <int>[];
    final start = _lowerBound(prefix);
    if (start >= length) return const <int>[];
    final results = <int>[];
    for (int i = start; i < length; i++) {
      final t = _termAt(i);
      if (!t.startsWith(prefix)) break;
      results.add(entryIds[i]);
      if (results.length >= limit) break;
    }
    return results;
  }
}
