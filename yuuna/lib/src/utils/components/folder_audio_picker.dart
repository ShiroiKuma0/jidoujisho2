import 'dart:io';

import 'package:flutter/material.dart';

/// Full-screen directory-tree browser rooted at Android's external
/// storage (`/storage/emulated/0/`). Lists subdirectories and files
/// whose extension matches [allowedExtensions], lets the user
/// navigate in/out, and returns the full path of the tapped file via
/// `Navigator.pop(context, path)` — or `null` if the user backs out
/// without picking anything.
///
/// Exists because `file_picker`'s SAF-backed implementation on some
/// Android OEM builds (Huawei EMUI/HarmonyOS confirmed, others
/// suspected) materialises the picked file by copying it into
/// app-private cache under `/data/user/0/<pkg>/cache/file_picker/`
/// before returning its path. The caller then can't enumerate the
/// picked file's siblings in the user's actual audiobook folder,
/// which breaks chapter-navigation and companion-srt auto-attach.
/// Walking the filesystem directly via `Directory.listSync()` (which
/// works because `MANAGE_EXTERNAL_STORAGE` is granted) keeps every
/// returned path on real storage, and the caller's downstream logic
/// just works.
class FolderAudioPicker extends StatefulWidget {
  const FolderAudioPicker({
    super.key,
    this.initialDir,
    this.allowedExtensions = const [
      '.mp3',
      '.m4a',
      '.ogg',
      '.wav',
      '.flac',
      '.aac',
    ],
  });

  /// Directory to open first. If null — or if it resolves to a path
  /// outside the external-storage root (e.g. a cache path saved from
  /// a previous app version that used `file_picker`) — the browser
  /// starts at [_rootDir] instead so the user isn't trapped in
  /// app-private storage.
  final String? initialDir;

  /// Lowercase extensions including the leading dot. Non-matching
  /// files are hidden from the listing; directories are always shown
  /// regardless of their name.
  final List<String> allowedExtensions;

  @override
  State<FolderAudioPicker> createState() => _FolderAudioPickerState();
}

class _FolderAudioPickerState extends State<FolderAudioPicker> {
  static const String _rootDir = '/storage/emulated/0';

  late String _currentDir;
  List<FileSystemEntity> _entries = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    final requested = widget.initialDir;
    if (requested != null &&
        requested.startsWith(_rootDir) &&
        Directory(requested).existsSync()) {
      _currentDir = requested;
    } else {
      _currentDir = _rootDir;
    }
    _loadDir();
  }

  void _loadDir() {
    try {
      final dir = Directory(_currentDir);
      if (!dir.existsSync()) {
        setState(() {
          _error = 'Directory does not exist';
          _entries = [];
        });
        return;
      }
      final all = dir.listSync(followLinks: false);
      // Filter: always include directories, include files only when
      // their extension is in the allow-list, hide dotfile/dotdir
      // entries so the listing doesn't fill with app-private noise
      // like `.thumbnails` or `.trashed-*`.
      final filtered = all.where((e) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) return false;
        if (e is Directory) return true;
        if (e is File) {
          final lower = e.path.toLowerCase();
          return widget.allowedExtensions.any(lower.endsWith);
        }
        return false;
      }).toList();
      // Directories first, then files; within each group sort
      // case-insensitive by basename.
      filtered.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
        final aName = a.path.split(Platform.pathSeparator).last.toLowerCase();
        final bName = b.path.split(Platform.pathSeparator).last.toLowerCase();
        return aName.compareTo(bName);
      });
      setState(() {
        _entries = filtered;
        _error = null;
      });
    } catch (e) {
      // Permission-denied on a subdirectory, or similar. Show the
      // error inline instead of blowing up the picker, and leave
      // the previous listing in place if any.
      setState(() {
        _error = 'Error listing directory: $e';
      });
    }
  }

  void _navigateTo(String path) {
    setState(() {
      _currentDir = path;
    });
    _loadDir();
  }

  void _goUp() {
    if (_currentDir == _rootDir) return;
    final parent = Directory(_currentDir).parent.path;
    // Refuse to walk above the external-storage root; nothing useful
    // for the user lives above it, and deep system paths vary across
    // Android flavours.
    if (parent.length < _rootDir.length) return;
    _navigateTo(parent);
  }

  @override
  Widget build(BuildContext context) {
    final relPath = _currentDir.length > _rootDir.length
        ? _currentDir.substring(_rootDir.length + 1)
        : '/';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Color(0xFFFFFF00)),
        title: Text(
          relPath,
          style: const TextStyle(
            color: Color(0xFFFFFF00),
            fontSize: 14,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_currentDir != _rootDir)
            IconButton(
              tooltip: 'Parent folder',
              icon: const Icon(Icons.arrow_upward),
              color: const Color(0xFFFFFF00),
              onPressed: _goUp,
            ),
        ],
      ),
      body: _entries.isEmpty && _error == null
          ? const Center(
              child: Text(
                '(empty)',
                style: TextStyle(color: Color(0xFFFFFF00)),
              ),
            )
          : Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(8),
                    color: const Color(0xFF220000),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFFFFF00)),
                    ),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (ctx, i) {
                      final entity = _entries[i];
                      final name =
                          entity.path.split(Platform.pathSeparator).last;
                      final isDir = entity is Directory;
                      return ListTile(
                        leading: Icon(
                          isDir ? Icons.folder : Icons.audio_file,
                          color: const Color(0xFFFFFF00),
                        ),
                        title: Text(
                          name,
                          style:
                              const TextStyle(color: Color(0xFFFFFF00)),
                        ),
                        onTap: () {
                          if (isDir) {
                            _navigateTo(entity.path);
                          } else {
                            Navigator.pop(context, entity.path);
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
