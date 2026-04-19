import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:isar/isar.dart';
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/language.dart';
import 'package:yuuna/models.dart';

/// Language implementation of the Czech language.
class CzechLanguage extends Language {
  CzechLanguage._privateConstructor()
      : super(
          languageName: 'Čeština',
          languageCode: 'cs',
          countryCode: 'CZ',
          threeLetterCode: 'ces',
          preferVerticalReading: false,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: true,
          textBaseline: TextBaseline.alphabetic,
          helloWorld: 'Ahoj světe',
          prepareSearchResults: prepareSearchResultsCzechLanguage,
          standardFormat: MigakuFormat.instance,
          defaultFontFamily: 'Roboto',
        );

  /// Get the singleton instance of this language.
  static CzechLanguage get instance => _instance;
  static final CzechLanguage _instance = CzechLanguage._privateConstructor();

  @override
  Future<void> prepareResources() async {}

  @override
  List<String> textToWords(String text) {
    List<String> splitText = text.splitWithDelim(RegExp(r'[-\n\r\s]+'));
    return splitText
        .mapIndexed((index, element) {
          if (index.isEven && index + 1 < splitText.length) {
            return [splitText[index], splitText[index + 1]].join();
          } else if (index + 1 == splitText.length) {
            return splitText[index];
          } else {
            return '';
          }
        })
        .where((e) => e.isNotEmpty)
        .toList();
  }
}

/// Top-level function for use in compute. See [Language] for details.
Future<int?> prepareSearchResultsCzechLanguage(
    DictionarySearchParams params) async {
  final Isar database = await Isar.open(
    globalSchemas,
    directory: params.directoryPath,
    maxSizeMiB: 8192,
  );

  int bestLength = 0;
  String searchTerm = params.searchTerm.toLowerCase().trim();
  if (searchTerm.isEmpty) return null;

  int maximumHeadings = params.maximumDictionarySearchResults;
  Map<int, DictionaryHeading> uniqueHeadingsById = {};

  int limit() => maximumHeadings - uniqueHeadingsById.length;

  bool shouldSearchWildcards = params.searchWithWildcards &&
      (searchTerm.contains('*') || searchTerm.contains('?'));

  if (shouldSearchWildcards) {
    bool noExactMatches = database.dictionaryHeadings
        .where()
        .termEqualTo(searchTerm)
        .isEmptySync();

    if (noExactMatches) {
      String matchesTerm = searchTerm;
      bool questionMarkOnly = !matchesTerm.contains('*');
      String noAsterisks = searchTerm.replaceAll('*', '').replaceAll('?', '');

      if (params.maximumDictionaryTermsInResult > uniqueHeadingsById.length) {
        List<DictionaryHeading> termMatchHeadings;
        if (questionMarkOnly) {
          termMatchHeadings = database.dictionaryHeadings
              .where()
              .termLengthEqualTo(searchTerm.length)
              .filter()
              .termMatches(matchesTerm, caseSensitive: false)
              .and()
              .entriesIsNotEmpty()
              .limit(limit())
              .findAllSync();
        } else {
          termMatchHeadings = database.dictionaryHeadings
              .where()
              .termLengthGreaterThan(noAsterisks.length, include: true)
              .filter()
              .termMatches(matchesTerm, caseSensitive: false)
              .and()
              .entriesIsNotEmpty()
              .limit(limit())
              .findAllSync();
        }
        uniqueHeadingsById.addEntries(
          termMatchHeadings.map((h) => MapEntry(h.id, h)),
        );
      }
    }
  } else {
    Map<int, List<DictionaryHeading>> exactByLength = {};
    Map<int, List<DictionaryHeading>> startsWithByLength = {};

    List<String> segments = searchTerm.splitWithDelim(RegExp('[ -]'));
    if (segments.length > 20) segments = segments.sublist(0, 10);

    String firstWord = segments.removeAt(0);
    segments = [
      if (firstWord.length >= 3) ...firstWord.split('') else firstWord,
    ];

    for (int i = 0; i < segments.length; i++) {
      String partialTerm = segments.sublist(0, segments.length - i).join();
      if (partialTerm.endsWith(' ')) continue;

      List<DictionaryHeading> exact = database.dictionaryHeadings
          .where(sort: Sort.desc)
          .termEqualTo(partialTerm)
          .limit(limit())
          .findAllSync();

      if (exact.isNotEmpty) {
        exactByLength[partialTerm.length] = exact;
        bestLength = partialTerm.length;
      }

      if (partialTerm.length >= 3) {
        List<DictionaryHeading> startsWith = database.dictionaryHeadings
            .where()
            .termStartsWith(partialTerm)
            .sortByTermLength()
            .limit(limit())
            .findAllSync();
        if (startsWith.isNotEmpty) {
          startsWithByLength[partialTerm.length] = startsWith;
          bestLength = partialTerm.length;
        }
      }
    }

    for (int length = searchTerm.length; length > 0; length--) {
      uniqueHeadingsById.addEntries(
        (exactByLength[length] ?? []).map((h) => MapEntry(h.id, h)),
      );
    }
    for (int length = searchTerm.length; length > 0; length--) {
      uniqueHeadingsById.addEntries(
        (startsWithByLength[length] ?? []).map((h) => MapEntry(h.id, h)),
      );
    }
  }

  List<DictionaryHeading> headings =
      uniqueHeadingsById.values.where((e) => e.entries.isNotEmpty).toList();
  if (headings.isEmpty) return null;

  DictionarySearchResult unsortedResult = DictionarySearchResult(
    searchTerm: searchTerm,
    bestLength: bestLength,
  );
  unsortedResult.headings.addAll(headings);

  late int resultId;
  database.writeTxnSync(() async {
    database.dictionarySearchResults.deleteBySearchTermSync(searchTerm);
    resultId = database.dictionarySearchResults.putSync(unsortedResult);
  });

  preloadResultSync(resultId);

  headings = headings.sublist(
      0, min(headings.length, params.maximumDictionaryTermsInResult));

  DictionarySearchResult result = DictionarySearchResult(
    id: resultId,
    searchTerm: searchTerm,
    bestLength: bestLength,
    headingIds: headings.map((e) => e.id).toList(),
  );

  database.writeTxnSync(() async {
    resultId = database.dictionarySearchResults.putSync(result);
    int count = database.dictionarySearchResults.countSync();
    if (params.maximumDictionarySearchResults < count) {
      int surplus = count - params.maximumDictionarySearchResults;
      database.dictionarySearchResults
          .where()
          .limit(surplus)
          .build()
          .deleteAllSync();
    }
  });

  return resultId;
}
