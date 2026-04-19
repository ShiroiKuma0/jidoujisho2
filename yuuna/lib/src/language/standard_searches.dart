import 'dart:async';

import 'package:collection/collection.dart';
import 'package:isar/isar.dart';
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/models.dart';
import 'package:yuuna/src/language/language_utils.dart';

/// Shared search helpers used by multiple language implementations to
/// avoid duplicating the same query orchestration. Each helper opens
/// Isar, runs queries, populates a [SearchResultBuilder], and returns
/// the assembled [SearchResultData].
///
/// Languages that need extra preprocessing (Russian's ё/е normalisation,
/// English's contraction expansion + lemmatisation, Japanese's elaborate
/// deinflection chain) implement their own search functions but reuse
/// the same [SearchResultBuilder] pattern so the post-processing stays
/// uniform.

/// Standard Latin-script language search.
///
/// Algorithm (per the original German/Czech/Polish/Ukrainian impls, now
/// adapted to the flat schema):
///   1. Normalise to lower-case.
///   2. Split on `[ -]`, then for the first word split character-by-
///      character to produce progressively-shorter prefixes.
///   3. For each prefix length: try exact match against the indexed
///      `term` field, then try `startsWith` (only for prefixes ≥ 3
///      characters).
///   4. Insert results into a [SearchResultBuilder] in priority order:
///      longest exact first, then longest starts-with.
///   5. Build the final [SearchResultData] (groups by (term, reading),
///      attaches pitch/freq ids).
///
/// [extraTermVariants], if provided, is called for each candidate prefix
/// and may return additional spellings to query (e.g. Russian's ё→е
/// folding). Each returned variant is queried independently and all
/// matching entries are added to the builder.
Future<SearchResultData?> runStandardLatinSearch(
  DictionarySearchParams params, {
  List<String> Function(String prefix)? extraTermVariants,
}) async {
  final database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  String searchTerm = params.searchTerm.toLowerCase().trim();
  if (searchTerm.isEmpty) return null;

  final maxGroups = params.maximumDictionaryTermsInResult;
  final builder =
      SearchResultBuilder(searchTerm: searchTerm, maxGroups: maxGroups);

  // Each group can have multiple entries (from multiple dicts); over-
  // fetch entries so we have enough material to fill every group slot
  // even when many entries share a (term, reading).
  int entryFetchLimit() {
    final remaining = builder.remainingGroups();
    if (remaining <= 0) return 0;
    return remaining * 8;
  }

  final shouldSearchWildcards = params.searchWithWildcards &&
      (searchTerm.contains('*') || searchTerm.contains('?'));

  if (shouldSearchWildcards) {
    final noExactMatches = database.dictionaryEntrys
        .where()
        .termEqualTo(searchTerm)
        .isEmptySync();

    if (noExactMatches) {
      final matchesTerm = searchTerm;
      final questionMarkOnly = !matchesTerm.contains('*');
      final noAsterisks = searchTerm.replaceAll('*', '').replaceAll('?', '');

      final lim = entryFetchLimit();
      if (lim > 0) {
        List<DictionaryEntry> entries;
        if (questionMarkOnly) {
          entries = database.dictionaryEntrys
              .where()
              .termLengthEqualTo(searchTerm.length)
              .filter()
              .termMatches(matchesTerm, caseSensitive: false)
              .limit(lim)
              .findAllSync();
        } else {
          entries = database.dictionaryEntrys
              .where()
              .termLengthGreaterThan(noAsterisks.length, include: true)
              .filter()
              .termMatches(matchesTerm, caseSensitive: false)
              .limit(lim)
              .findAllSync();
        }
        builder.addEntries(entries);
        if (entries.isNotEmpty) builder.recordMatchLength(searchTerm.length);
      }
    }
  } else {
    List<String> segments = searchTerm.splitWithDelim(RegExp('[ -]'));
    if (segments.length > 20) segments = segments.sublist(0, 10);

    final firstWord = segments.removeAt(0);
    segments = [
      if (firstWord.length >= 3) ...firstWord.split('') else firstWord,
    ];

    final exactByLength = <int, List<DictionaryEntry>>{};
    final startsWithByLength = <int, List<DictionaryEntry>>{};

    for (int i = 0; i < segments.length; i++) {
      final partialTerm = segments.sublist(0, segments.length - i).join();
      if (partialTerm.endsWith(' ')) continue;
      if (entryFetchLimit() <= 0) break;

      final variants = extraTermVariants != null
          ? extraTermVariants(partialTerm)
          : <String>[partialTerm];

      // Exact match.
      final exact = <DictionaryEntry>[];
      for (final variant in variants) {
        if (entryFetchLimit() <= 0) break;
        exact.addAll(database.dictionaryEntrys
            .where(sort: Sort.desc)
            .termEqualTo(variant)
            .limit(entryFetchLimit())
            .findAllSync());
      }
      if (exact.isNotEmpty) {
        exactByLength[partialTerm.length] = exact;
        builder.recordMatchLength(partialTerm.length);
      }

      // Starts-with (only for non-trivial prefixes).
      if (partialTerm.length >= 3) {
        final startsWith = <DictionaryEntry>[];
        for (final variant in variants) {
          if (entryFetchLimit() <= 0) break;
          startsWith.addAll(database.dictionaryEntrys
              .where()
              .termStartsWith(variant)
              .sortByTermLength()
              .limit(entryFetchLimit())
              .findAllSync());
        }
        if (startsWith.isNotEmpty) {
          startsWithByLength[partialTerm.length] = startsWith;
          builder.recordMatchLength(partialTerm.length);
        }
      }
    }

    // Insert in priority order: longest exact first, then longest
    // starts-with. Tie-breaks within the builder use insertion order.
    for (int length = searchTerm.length; length > 0; length--) {
      final batch = exactByLength[length];
      if (batch != null) builder.addEntries(batch);
    }
    for (int length = searchTerm.length; length > 0; length--) {
      final batch = startsWithByLength[length];
      if (batch != null) builder.addEntries(batch);
    }
  }

  return builder.build(database);
}
