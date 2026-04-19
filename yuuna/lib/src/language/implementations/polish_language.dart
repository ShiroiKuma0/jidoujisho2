import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/language.dart';

/// Language implementation of the Polish language.
class PolishLanguage extends Language {
  PolishLanguage._privateConstructor()
      : super(
          languageName: 'Polski',
          languageCode: 'pl',
          countryCode: 'PL',
          threeLetterCode: 'pol',
          preferVerticalReading: false,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: true,
          textBaseline: TextBaseline.alphabetic,
          helloWorld: 'Witaj świecie',
          prepareSearchResults: prepareSearchResultsPolishLanguage,
          standardFormat: MigakuFormat.instance,
          defaultFontFamily: 'Roboto',
        );

  /// Get the singleton instance of this language.
  static PolishLanguage get instance => _instance;
  static final PolishLanguage _instance = PolishLanguage._privateConstructor();

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

/// Top-level function for use in compute. See [runStandardLatinSearch].
Future<SearchResultData?> prepareSearchResultsPolishLanguage(
    DictionarySearchParams params) async {
  return runStandardLatinSearch(params);
}
