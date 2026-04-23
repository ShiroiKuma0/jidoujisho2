import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:yuuna/dictionary.dart';
import 'package:yuuna/language.dart';

/// Language implementation of the Russian language.
class RussianLanguage extends Language {
  RussianLanguage._privateConstructor()
      : super(
          languageName: 'Русский',
          languageCode: 'ru',
          countryCode: 'RU',
          threeLetterCode: 'rus',
          preferVerticalReading: false,
          textDirection: TextDirection.ltr,
          isSpaceDelimited: true,
          textBaseline: TextBaseline.alphabetic,
          helloWorld: 'Привет мир',
          prepareSearchResults: prepareSearchResultsRussianLanguage,
          standardFormat: MigakuFormat.instance,
          defaultFontFamily: 'Roboto',
        );

  /// Get the singleton instance of this language.
  static RussianLanguage get instance => _instance;
  static final RussianLanguage _instance =
      RussianLanguage._privateConstructor();

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

/// Russian-specific: returns the original form plus the ё→е folded form
/// when they differ. Many Russian dictionaries store words without the
/// diaeresis even when the headword carries it (and vice versa), so we
/// query both spellings.
List<String> _yoYeVariants(String prefix) {
  final folded = prefix.replaceAll('ё', 'е').replaceAll('Ё', 'Е');
  if (folded == prefix) return <String>[prefix];
  return <String>[prefix, folded];
}

/// Top-level function for use in compute. See [runStandardLatinSearch].
Future<SearchResultData?> prepareSearchResultsRussianLanguage(
    DictionarySearchParams params) async {
  return runStandardLatinSearch(
    params,
    extraTermVariants: _yoYeVariants,
  );
}
