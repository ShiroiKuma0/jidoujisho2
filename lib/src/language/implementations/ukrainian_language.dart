import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:shiroikumanojisho/dictionary.dart';
import 'package:shiroikumanojisho/language.dart';

/// Language implementation of the Ukrainian language.
class UkrainianLanguage extends Language {
  UkrainianLanguage._privateConstructor()
      : super(
          languageName: 'Українська',
          languageCode: 'uk',
          countryCode: 'UA',
          threeLetterCode: 'ukr',
          preferVerticalReading: false,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: true,
          textBaseline: TextBaseline.alphabetic,
          helloWorld: 'Привіт світ',
          prepareSearchResults: prepareSearchResultsUkrainianLanguage,
          standardFormat: MigakuFormat.instance,
          defaultFontFamily: 'Roboto',
        );

  /// Get the singleton instance of this language.
  static UkrainianLanguage get instance => _instance;
  static final UkrainianLanguage _instance =
      UkrainianLanguage._privateConstructor();

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
Future<SearchResultData?> prepareSearchResultsUkrainianLanguage(
    DictionarySearchParams params) async {
  return runStandardLatinSearch(params);
}
