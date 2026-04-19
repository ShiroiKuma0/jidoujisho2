import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

/// Utilities for cleaning up dictionary resource directories.
///
/// After a dictionary is imported, the parsed contents of `term_bank_*.json`,
/// `term_meta_bank_*.json`, `kanji_bank_*.json`, `kanji_meta_bank_*.json`,
/// `tag_bank_*.json` and `index.json` are stored in the Isar database and the
/// raw JSON files are no longer needed. They were previously kept on disk
/// indefinitely, wasting hundreds of megabytes per install.
///
/// Image, audio, CSS and any other assets referenced by structured dictionary
/// content (via `jidoujisho://` URLs) are still required at render time and
/// are preserved.
class DictionaryResourceCleanup {
  DictionaryResourceCleanup._();

  /// Filename patterns that contain only data already parsed into Isar and
  /// can be safely deleted after a successful import.
  static final List<RegExp> _bankFilePatterns = [
    RegExp(r'^term_bank_\d+\.json$'),
    RegExp(r'^term_meta_bank_\d+\.json$'),
    RegExp(r'^kanji_bank_\d+\.json$'),
    RegExp(r'^kanji_meta_bank_\d+\.json$'),
    RegExp(r'^tag_bank_\d+\.json$'),
  ];

  /// Filenames (not patterns) that are also parsed at import and can be
  /// dropped. `index.json` is the dictionary metadata, also stored in Isar.
  static const List<String> _bankFilenames = ['index.json'];

  /// Returns true if [name] matches a known bank file pattern.
  static bool isBankFile(String name) {
    if (_bankFilenames.contains(name)) return true;
    for (final pattern in _bankFilePatterns) {
      if (pattern.hasMatch(name)) return true;
    }
    return false;
  }

  /// Delete bank JSON files from a single dictionary resource directory.
  ///
  /// Returns the total number of bytes freed.
  static int cleanupBankFiles(Directory dir) {
    if (!dir.existsSync()) return 0;

    int bytesFreed = 0;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        final basename = path.basename(entity.path);
        if (!isBankFile(basename)) continue;
        try {
          final size = entity.lengthSync();
          entity.deleteSync();
          bytesFreed += size;
        } catch (e) {
          debugPrint(
              'DictionaryResourceCleanup: failed to delete ${entity.path}: $e');
        }
      }
    } catch (e) {
      debugPrint(
          'DictionaryResourceCleanup: failed to list ${dir.path}: $e');
    }
    return bytesFreed;
  }

  /// Walk all per-dictionary subdirectories of [parentDir] (the
  /// dictionaryResources root) and clean up bank files in each.
  ///
  /// Returns the total number of bytes freed across all dictionaries.
  static int cleanupAllDictionaries(Directory parentDir) {
    if (!parentDir.existsSync()) return 0;

    int totalFreed = 0;
    int dirsCleaned = 0;
    try {
      for (final entity in parentDir.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final freed = cleanupBankFiles(entity);
        if (freed > 0) {
          dirsCleaned++;
          totalFreed += freed;
        }
      }
    } catch (e) {
      debugPrint(
          'DictionaryResourceCleanup: failed to walk ${parentDir.path}: $e');
    }

    if (totalFreed > 0) {
      debugPrint(
          'DictionaryResourceCleanup: freed ${_formatBytes(totalFreed)} '
          'across $dirsCleaned dictionaries');
    }
    return totalFreed;
  }

  /// Compute the recursive size of a directory in bytes.
  static int directorySize(Directory dir) {
    if (!dir.existsSync()) return 0;
    int total = 0;
    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += entity.lengthSync();
          } catch (_) {
            // Permission error or file vanished mid-walk; ignore.
          }
        }
      }
    } catch (e) {
      debugPrint('DictionaryResourceCleanup: failed to size ${dir.path}: $e');
    }
    return total;
  }

  /// Recursively delete the contents of a directory without removing the
  /// directory itself. Returns bytes freed.
  static int clearDirectoryContents(Directory dir) {
    if (!dir.existsSync()) return 0;
    int total = 0;
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        try {
          if (entity is File) {
            total += entity.lengthSync();
            entity.deleteSync();
          } else if (entity is Directory) {
            total += directorySize(entity);
            entity.deleteSync(recursive: true);
          }
        } catch (e) {
          debugPrint(
              'DictionaryResourceCleanup: failed to delete ${entity.path}: $e');
        }
      }
    } catch (e) {
      debugPrint(
          'DictionaryResourceCleanup: failed to list ${dir.path}: $e');
    }
    return total;
  }

  /// Human-readable byte string for log output.
  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
