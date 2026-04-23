import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/language.dart';

/// Language implementation of the German language.
class GermanLanguage extends Language {
  GermanLanguage._privateConstructor()
      : super(
          languageName: 'Deutsch',
          languageCode: 'de',
          countryCode: 'DE',
          threeLetterCode: 'deu',
          preferVerticalReading: false,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: true,
          textBaseline: TextBaseline.alphabetic,
          helloWorld: 'Hallo Welt',
          prepareSearchResults: prepareSearchResultsGermanLanguage,
          standardFormat: MigakuFormat.instance,
          defaultFontFamily: 'Roboto',
        );

  /// Get the singleton instance of this language.
  static GermanLanguage get instance => _instance;
  static final GermanLanguage _instance = GermanLanguage._privateConstructor();

  @override
  Future<void> prepareResources() async {}

  @override
  List<String> textToWords(String text) {
    final splitText = text.splitWithDelim(RegExp(r'[-\n\r\s]+'));
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

/// Top-level function for use in compute. See [runStandardLatinSearch] for
/// the algorithm.
Future<SearchResultData?> prepareSearchResultsGermanLanguage(
    DictionarySearchParams params) async {
  return runStandardLatinSearch(params);
}
