import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_archive/flutter_archive.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;
import 'package:share_plus/share_plus.dart';
import 'package:shiroikumanojisho/models.dart';

/// Handles full app data backup and restore.
class AppBackupRestore {
  /// Create a backup ZIP of all app data.
  static Future<void> createBackup({
    required AppModel appModel,
    required BuildContext context,
  }) async {
    final navigator = Navigator.of(context);

    // Show progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 24),
            Expanded(child: Text('Creating backup...\nThis may take a while.')),
          ],
        ),
      ),
    );

    try {
      // The app data root contains all app state:
      // app_flutter/ (Hive), files/ (Isar), app_webview/ (IndexedDB), etc.
      final dataRoot = appModel.appDirectory.parent;

      final staging = Directory(
          path.join(appModel.temporaryDirectory.path, 'backup_staging'));
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);

      // Copy entire data root, skipping cache and temp directories.
      // `app_hws_webview` (Huawei's built-in WebView) and `app_webview`
      // (the standard Android WebView) are intentionally NOT top-level
      // excluded: their `IndexedDB/` and `Local Storage/` subdirectories
      // hold TTU's books and reader settings respectively. The
      // `skipNested` set below keeps their cache subdirectories
      // (`Cache`, `Code Cache`, `GPU Cache`, `CacheStorage`) out of the
      // backup at any depth, which is enough to keep the zip to a
      // reasonable size without throwing away the user's library.
      await _copyDirectory(
        dataRoot,
        staging,
        skip: {
          'cache',
          'code_cache',
          'dictionaryImportWorkingDirectory',
          'backup_staging',
          'backup_restore',
        },
        skipNested: const {
          'Cache',
          'Code Cache',
          'GPU Cache',
          'GPUCache',
          'CacheStorage',
          'Crashpad',
          'pending_crash_reports',
        },
      );

      // Create ZIP
      final timestamp =
          DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());
      final filename =
          'shiroikumanojisho_backup_$timestamp.zip';

      final tmpDir = Directory('/storage/emulated/0/tmp');
      if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
      final zipFile = File(path.join(tmpDir.path, filename));
      if (zipFile.existsSync()) zipFile.deleteSync();

      await ZipFile.createFromDirectory(
        sourceDir: staging,
        zipFile: zipFile,
      );

      // Cleanup staging
      staging.deleteSync(recursive: true);

      // Close progress dialog
      if (navigator.canPop()) navigator.pop();

      // Show result dialog with share option
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Backup complete'),
            content: Text('Saved to:\n${zipFile.path}'),
            actions: [
              TextButton(
                onPressed: () {
                  Share.shareFiles([zipFile.path],
                      mimeTypes: ['application/zip']);
                },
                child: const Text('Share'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (navigator.canPop()) navigator.pop();
      debugPrint('Backup error: $e');
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Backup failed'),
            content: Text('$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  /// Restore app data from a backup ZIP.
  static Future<void> restoreBackup({
    required AppModel appModel,
    required BuildContext context,
  }) async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (result == null || result.files.single.path == null) return;

      final zipPath = result.files.single.path!;
      final zipFile = File(zipPath);

      // Confirm restore
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore backup'),
          content: Text(
              'Restore from:\n${path.basename(zipPath)}\n\n'
              'This will replace all current app data. '
              'The app will close after restore.\n\nContinue?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore',
                  style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (confirmed != true) return;

      final navigator = Navigator.of(context);

      // Show progress dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 24),
              Expanded(
                  child: Text('Restoring backup...\nThis may take a while.')),
            ],
          ),
        ),
      );

      // Extract to temp
      final extractDir = Directory(
          path.join(appModel.temporaryDirectory.path, 'backup_restore'));
      if (extractDir.existsSync()) extractDir.deleteSync(recursive: true);
      extractDir.createSync(recursive: true);

      await ZipFile.extractToDirectory(
        zipFile: zipFile,
        destinationDir: extractDir,
      );

      // Determine backup format
      final dataRoot = appModel.appDirectory.parent;
      final isRootBackup =
          !Directory(path.join(extractDir.path, 'app')).existsSync();

      if (isRootBackup) {
        // New format: entire data root
        await _clearDirectory(dataRoot,
            skip: {'cache', 'code_cache', 'lib', 'backup_restore'});
        await _copyDirectory(extractDir, dataRoot);
      } else {
        // Legacy format: app/ + db/ + webview/
        final appBackup = Directory(path.join(extractDir.path, 'app'));
        final dbBackup = Directory(path.join(extractDir.path, 'db'));

        if (!appBackup.existsSync() || !dbBackup.existsSync()) {
          if (navigator.canPop()) navigator.pop();
          Fluttertoast.showToast(msg: 'Invalid backup file');
          extractDir.deleteSync(recursive: true);
          return;
        }

        await _clearDirectory(appModel.appDirectory,
            skip: {'dictionaryImportWorkingDirectory'});
        await _copyDirectory(appBackup, appModel.appDirectory);

        await _clearDirectory(appModel.databaseDirectory);
        await _copyDirectory(dbBackup, appModel.databaseDirectory);

        final wvBackup = Directory(path.join(extractDir.path, 'webview'));
        if (wvBackup.existsSync()) {
          final webviewDir = Directory(
              path.join(appModel.appDirectory.parent.path, 'app_webview'));
          if (webviewDir.existsSync()) {
            await _clearDirectory(webviewDir);
          }
          await _copyDirectory(wvBackup, webviewDir);
        }
      }

      // Cleanup
      extractDir.deleteSync(recursive: true);

      if (navigator.canPop()) navigator.pop();

      Fluttertoast.showToast(msg: 'Restore complete. Closing app...');

      // Exit app so it reinitializes with restored data
      await Future.delayed(const Duration(seconds: 2));
      exit(0);
    } catch (e) {
      debugPrint('Restore error: $e');
      if (context.mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Restore failed'),
            content: Text('$e'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    }
  }

  /// Recursively copy a directory.
  ///
  /// [skip] applies only at the top level — names matching are skipped.
  /// [skipNested] applies at any depth — directories matching are skipped
  /// regardless of where they appear in the tree (used for cache dirs that
  /// browsers/WebViews scatter through their data directory).
  static Future<void> _copyDirectory(
    Directory source,
    Directory destination, {
    Set<String> skip = const {},
    Set<String> skipNested = const {},
  }) async {
    if (!destination.existsSync()) {
      destination.createSync(recursive: true);
    }

    await for (var entity in source.list()) {
      final name = path.basename(entity.path);
      if (skip.contains(name)) continue;
      if (skipNested.contains(name)) continue;

      final destPath = path.join(destination.path, name);
      if (entity is File) {
        await entity.copy(destPath);
      } else if (entity is Directory) {
        // Pass an empty `skip` to nested calls (top-level-only filter), but
        // continue propagating `skipNested` all the way down.
        await _copyDirectory(
          entity,
          Directory(destPath),
          skipNested: skipNested,
        );
      }
    }
  }

  /// Clear contents of a directory without deleting the directory itself.
  static Future<void> _clearDirectory(
    Directory directory, {
    Set<String> skip = const {},
  }) async {
    if (!directory.existsSync()) return;

    await for (var entity in directory.list()) {
      final name = path.basename(entity.path);
      if (skip.contains(name)) continue;

      if (entity is File) {
        await entity.delete();
      } else if (entity is Directory) {
        await entity.delete(recursive: true);
      }
    }
  }
}
