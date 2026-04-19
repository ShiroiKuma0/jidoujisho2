import 'package:collection/collection.dart';
import 'package:yuuna/dictionary.dart';

/// An in-memory view model that groups `(term, reading)` together with
/// its dictionary entries, pitch-accent rows, frequency rows, and
/// display tags.
///
/// Previously a persisted Isar collection; now assembled on demand by
/// `AppModel.searchDictionary` after a search worker returns a
/// [SearchResultData]. Keeping this as a plain Dart class preserves the
/// interface that creator fields (meaning, frequency, pitch accent,
/// term, reading, sentence, tags…) and language override widgets have
/// been relying on, while removing the storage cost and link-table
/// traversal of the Isar version.
class DictionaryHeading {
  /// Build a heading from its constituent parts. Callers are
  /// responsible for populating [entries], [pitches], [frequencies] and
  /// [tags] with rows that actually apply to `(term, reading)`.
  DictionaryHeading({
    required this.term,
    this.reading = '',
    List<DictionaryEntry>? entries,
    List<DictionaryPitch>? pitches,
    List<DictionaryFrequency>? frequencies,
    List<DictionaryTag>? tags,
  })  : entries = entries ?? <DictionaryEntry>[],
        pitches = pitches ?? <DictionaryPitch>[],
        frequencies = frequencies ?? <DictionaryFrequency>[],
        tags = tags ?? <DictionaryTag>[];

  /// Function to generate a stable integer lookup id for a heading by
  /// its `(term, reading)` composite key. Retained for callers that
  /// need to produce a hash key compatible with older Isar-backed code
  /// paths (e.g. single-kanji prioritisation during migration).
  static int hash({required String term, required String reading}) {
    return fastHash('$term/$reading');
  }

  /// The stable integer id for this heading's `(term, reading)` pair.
  int get id => hash(term: term, reading: reading);

  /// The headword.
  final String term;

  /// The reading (alternate form). Empty for languages that do not use
  /// distinct readings.
  final String reading;

  /// Length of [term]. Mirrors the old index field so call sites can
  /// read it the same way.
  int get termLength => term.length;

  /// All dictionary entries that share this `(term, reading)` pair,
  /// typically across multiple imported dictionaries. Assembled at
  /// search time.
  final List<DictionaryEntry> entries;

  /// All pitch-accent annotations that apply to this `(term, reading)`.
  final List<DictionaryPitch> pitches;

  /// All frequency annotations that apply to this `(term, reading)`.
  final List<DictionaryFrequency> frequencies;

  /// Display-metadata tags applicable to this heading. Populated by
  /// `AppModel.searchDictionary` from the per-entry `entryTagsRaw` /
  /// `headingTagsRaw` strings plus the per-dictionary tag lookup tables.
  final List<DictionaryTag> tags;

  /// Sum of popularity of all dictionary entries belonging to this
  /// heading.
  double get popularitySum =>
      entries.map((entry) => entry.popularity).sum;

  @override
  bool operator ==(Object other) =>
      other is DictionaryHeading &&
      term == other.term &&
      reading == other.reading;

  @override
  int get hashCode => Object.hash(term, reading);
}
