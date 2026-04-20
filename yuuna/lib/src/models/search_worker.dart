import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:yuuna/dictionary.dart';

/// Persistent search-worker isolate.
///
/// Historically every dictionary search spawned a fresh isolate via
/// `compute()`. That path paid two fixed costs on every tap: ~50-150
/// ms of isolate spawn + ~100-300 ms of `Isar.open` on the cold
/// isolate (Isar caches the opened instance per-isolate). With ten-
/// ish taps per reading paragraph that adds up quickly.
///
/// This module owns a long-lived isolate that stays open for the
/// session. Isar is effectively opened once (the second call to
/// [Isar.open] within the same isolate returns the cached instance);
/// the worker receives search requests via a [ReceivePort] and
/// dispatches to the per-language `prepareSearchResults` functions
/// exactly the way `compute()` did. Results and `[WORKER-PERF]`
/// instrumentation lines travel back to the main isolate via the
/// captured [SendPort].
///
/// Phase 2 (in-memory term index) layers on top of this module by
/// caching per-language term lookups in the worker isolate's heap.
/// This file stays search-function-agnostic in Phase 1 — it's pure
/// plumbing.

/// Initial message sent from the main isolate when spawning the
/// worker. Carries the reply port the worker will use for all future
/// outbound messages (responses, perf lines, etc), plus the
/// [RootIsolateToken] that's needed to wire up platform plugins in
/// the spawned isolate.
class SearchWorkerInit {
  SearchWorkerInit({
    required this.replyPort,
    required this.rootIsolateToken,
  });

  /// The main isolate's aggregate [SendPort]. All outbound messages
  /// from the worker — search responses AND `[WORKER-PERF]` strings —
  /// go through this single port.
  final SendPort replyPort;

  /// Required to call [BackgroundIsolateBinaryMessenger.ensureInitialized]
  /// inside the spawned isolate. Without this setup, any Flutter
  /// plugin-channel call from the worker silently fails — Flutter's
  /// own `compute()` does this for you but `Isolate.spawn()` does
  /// not.
  final RootIsolateToken rootIsolateToken;
}

/// A search request sent from main to worker. The [id] is a
/// correlation number: main picks it, worker echoes it in the
/// matching [SearchWorkerResponse] so multiple in-flight requests
/// can be distinguished.
///
/// [prepareFn] is the per-language `prepareSearchResults*` function
/// reference. These are all top-level functions so Dart's isolate
/// message layer accepts them as message payload.
class SearchWorkerRequest {
  SearchWorkerRequest({
    required this.id,
    required this.prepareFn,
    required this.params,
  });

  final int id;
  final Future<SearchResultData?> Function(DictionarySearchParams) prepareFn;
  final DictionarySearchParams params;
}

/// Response from worker to main. Exactly one is sent per
/// [SearchWorkerRequest], identified by the matching [id].
///
/// [result] is null if the search returned no data (terminal empty
/// queries, etc). If the search threw, [error] carries the
/// stringified exception and [result] is null.
class SearchWorkerResponse {
  SearchWorkerResponse({
    required this.id,
    this.result,
    this.error,
  });

  final int id;
  final SearchResultData? result;
  final String? error;
}

/// Top-level worker entry point. Opens a [ReceivePort], sends its
/// [SendPort] back to main through the init reply port, then loops
/// on incoming messages until the isolate is killed.
///
/// The main isolate should:
///   1. Spawn this function via `Isolate.spawn<SearchWorkerInit>(
///      searchWorkerEntry, SearchWorkerInit(replyPort: myPort))`.
///   2. Wait on its own [ReceivePort] for the first message, which
///      will be the worker's [SendPort]. That's the handle for
///      submitting requests.
///   3. Send [SearchWorkerRequest]s. Await corresponding
///      [SearchWorkerResponse]s by id.
void searchWorkerEntry(SearchWorkerInit init) {
  // Bring the spawned isolate up to the same level of Flutter-
  // awareness as an isolate launched via `compute()`:
  //
  //   1. DartPluginRegistrant.ensureInitialized() registers the
  //      Dart-side of any plugins that rely on it (some plugins use
  //      annotations processed by the plugin registrar to inject
  //      setup code into spawned isolates).
  //   2. BackgroundIsolateBinaryMessenger.ensureInitialized(token)
  //      installs a platform-channel messenger so MethodChannel-
  //      based plugin calls from this isolate go to the host.
  //
  // Without these, any plugin-mediated call from the worker — or
  // anything transitively triggered by loading libraries that touch
  // plugins at init — silently throws. Isar itself is FFI-only and
  // doesn't need either, but imports that reach into the yuuna
  // codebase may pull in code that does, and matching compute()'s
  // setup exactly removes a whole class of "why is this broken"
  // failure modes.
  DartPluginRegistrant.ensureInitialized();
  BackgroundIsolateBinaryMessenger.ensureInitialized(
      init.rootIsolateToken);

  final receivePort = ReceivePort();
  init.replyPort.send(receivePort.sendPort);

  receivePort.listen((dynamic message) async {
    if (message is SearchWorkerRequest) {
      // Rewire the params' sendPort to the persistent reply port
      // before invoking the search function. The search functions
      // use `params.send(...)` for `[WORKER-PERF]` lines, and those
      // need to go to the main isolate's aggregate receivePort —
      // not to the per-request port that the old compute() model
      // created and tore down around every search.
      //
      // DictionarySearchParams fields are final, so we build a
      // fresh instance here. Cheap — handful of primitives plus a
      // small List<int> reference (not copied, shared).
      final params = DictionarySearchParams(
        searchTerm: message.params.searchTerm,
        maximumDictionarySearchResults:
            message.params.maximumDictionarySearchResults,
        maximumDictionaryTermsInResult:
            message.params.maximumDictionaryTermsInResult,
        enabledDictionaryIds: message.params.enabledDictionaryIds,
        searchWithWildcards: message.params.searchWithWildcards,
        sendPort: init.replyPort,
        directoryPath: message.params.directoryPath,
      );

      try {
        final result = await message.prepareFn(params);
        init.replyPort.send(SearchWorkerResponse(
          id: message.id,
          result: result,
        ));
      } catch (e, st) {
        // Mirror the error through the perf channel too so it lands
        // in the perf log alongside the `[SEARCH-PERF]` lines — easier
        // to correlate than waiting for logcat to surface the error
        // response.
        try {
          init.replyPort.send(
              '[WORKER-ERROR] id=${message.id} error=$e\n$st');
        } catch (_) {}
        init.replyPort.send(SearchWorkerResponse(
          id: message.id,
          error: '$e\n$st',
        ));
      }
    } else if (message == 'shutdown') {
      receivePort.close();
      Isolate.current.kill();
    }
  });
}
