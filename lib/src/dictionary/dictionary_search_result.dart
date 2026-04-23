import 'package:shiroikumanojisho/dictionary.dart';

/// An in-memory representation of a single dictionary search result,
/// produced by `AppModel.searchDictionary` after it post-processes a
/// [SearchResultData] from the worker isolate.
///
/// Previously this was a persisted Isar collection (one row per
/// distinct search term) whose `headings` `IsarLinks` was walked lazily
/// during render. In the flat schema we no longer persist search
/// results — history lives in memory and is capped via
/// `maximumDictionarySearchResults`. Having this as a plain class lets
/// every UI consumer (dictionary_term_page, dictionary_history_page,
/// dictionary_result_page, base_source_page…) keep its existing
/// interface.
class DictionarySearchResult {
  /// Construct a result. The [id] is assigned by
  /// `AppModel._nextSearchResultId()` so that providers keyed on the id
  /// (scroll-position rebuilds etc.) still work.
  DictionarySearchResult({
    required this.searchTerm,
    this.bestLength = 0,
    this.scrollPosition = 0,
    this.headings = const <DictionaryHeading>[],
    this.id,
  });

  /// An identifier used for provider-keyed rebuild paths. Non-null for
  /// results that have been registered in the in-memory history LRU.
  int? id;

  /// Original search term used to make the result.
  final String searchTerm;

  /// The best length found for the search term used for highlighting
  /// the selected word.
  final int bestLength;

  /// The current scroll position of the result in the dictionary
  /// history view. Mutable so the UI can save scroll state without
  /// needing to rebuild the result.
  int scrollPosition;

  /// The ordered list of heading view models in this result.
  final List<DictionaryHeading> headings;

  /// Convenience: heading ids in the same order, exposed for code paths
  /// that previously read `headingIds` directly.
  List<int> get headingIds => headings.map((h) => h.id).toList();
}
