import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:just_audio/just_audio.dart';
import 'package:multi_value_listenable_builder/multi_value_listenable_builder.dart';
import 'package:subtitle/subtitle.dart';
import 'package:yuuna/models.dart';
import 'package:yuuna/utils.dart';

/// A toolbar for playing audiobook MP3 files synced with SRT subtitles,
/// displayed at the bottom of the reader page.
class ReaderAudioToolbar extends StatefulWidget {
  const ReaderAudioToolbar({
    required this.bookKey,
    required this.appModel,
    this.onToggleSecondary,
    this.onOpenSecondaryManager,
    this.onRemoveSecondary,
    this.secondaryShown = false,
    this.hasSecondary = false,
    this.secondaryTitle,
    super.key,
  });

  final String bookKey;
  final AppModel appModel;
  final VoidCallback? onToggleSecondary;
  final VoidCallback? onOpenSecondaryManager;
  final VoidCallback? onRemoveSecondary;
  final bool secondaryShown;
  final bool hasSecondary;
  final String? secondaryTitle;

  @override
  State<ReaderAudioToolbar> createState() => ReaderAudioToolbarState();
}

class ReaderAudioToolbarState extends State<ReaderAudioToolbar> {
  final AudioPlayer _audioPlayer = AudioPlayer();

  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<bool> _playingNotifier = ValueNotifier(false);

  List<Subtitle> _subtitles = [];
  Subtitle? _currentSubtitle;
  Subtitle? _autoPauseMemory;
  bool _isSeeking = false;
  bool _sliderBeingDragged = false;
  bool _audioLoaded = false;
  bool _collapsed = true;

  String? _mp3Path;
  String? _srtPath;

  late Box _box;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration?>? _durationSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _box = await Hive.openBox('readerAudio');
    String key = _safeKey(widget.bookKey);
    _mp3Path = _box.get('mp3_$key');
    _srtPath = _box.get('srt_$key');

    if (_mp3Path != null && File(_mp3Path!).existsSync()) {
      await _loadAudio();
      if (_srtPath != null && File(_srtPath!).existsSync()) {
        await _loadSubtitles();
      }
      _collapsed = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    _saveAudioPosition();
    _positionSub?.cancel();
    _playerStateSub?.cancel();
    _durationSub?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  /// Save current audio position for resuming later.
  void _saveAudioPosition() {
    if (_audioLoaded && _positionNotifier.value > Duration.zero) {
      String key = _safeKey(widget.bookKey);
      _box.put('pos_$key', _positionNotifier.value.inMilliseconds);
    }
  }

  String _safeKey(String k) =>
      k.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

  Future<void> _persist() async {
    String key = _safeKey(widget.bookKey);
    if (_mp3Path != null) await _box.put('mp3_$key', _mp3Path!);
    if (_srtPath != null) await _box.put('srt_$key', _srtPath!);
  }

  Future<void> _loadAudio() async {
    if (_mp3Path == null) return;
    try {
      await _audioPlayer.setFilePath(_mp3Path!);
      double speed = (_box.get('playback_speed') as num?)?.toDouble() ?? 1.0;
      await _audioPlayer.setSpeed(speed);

      _durationSub?.cancel();
      _durationSub = _audioPlayer.durationStream.listen((d) {
        _durationNotifier.value = d ?? Duration.zero;
      });

      _positionSub?.cancel();
      _positionSub = _audioPlayer.positionStream.listen(_onPosition);

      _playerStateSub?.cancel();
      _playerStateSub = _audioPlayer.playerStateStream.listen((s) {
        _playingNotifier.value = s.playing;
      });

      // Restore saved position
      String key = _safeKey(widget.bookKey);
      int? savedPosMs = _box.get('pos_$key');
      if (savedPosMs != null && savedPosMs > 0) {
        await _audioPlayer.seek(Duration(milliseconds: savedPosMs));
      }

      _audioLoaded = true;
    } catch (e) {
      debugPrint('Error loading audio: $e');
      _audioLoaded = false;
    }
  }

  Future<void> _loadSubtitles() async {
    if (_srtPath == null) return;
    try {
      String content = await File(_srtPath!).readAsString();
      SubtitleController ctrl = SubtitleController(
        provider: SubtitleProvider.fromString(
          data: content,
          type: SubtitleType.srt,
        ),
      );
      await ctrl.initial();
      _subtitles = ctrl.subtitles;
    } catch (e) {
      debugPrint('Error loading subtitles: $e');
      _subtitles = [];
    }
  }

  void _onPosition(Duration pos) {
    if (!mounted || _isSeeking) return;
    _positionNotifier.value = pos;

    if (_subtitles.isEmpty) return;

    // Find current subtitle at this position
    Subtitle? newSub;
    for (Subtitle s in _subtitles) {
      if (pos >= s.start && pos <= s.end) {
        newSub = s;
        break;
      }
    }

    // Only act when subtitle state changes
    if (newSub != _currentSubtitle) {
      // Auto-pause: pause when leaving a subtitle
      if (widget.appModel.playbackMode == PlaybackMode.autoPausePlayback &&
          !_sliderBeingDragged &&
          _currentSubtitle != null &&
          _autoPauseMemory != _currentSubtitle) {
        _audioPlayer.pause();
        _autoPauseMemory = _currentSubtitle;
      }

      // Condensed playback: skip gaps between subtitles
      if (widget.appModel.playbackMode == PlaybackMode.condensedPlayback &&
          _audioPlayer.playing &&
          !_sliderBeingDragged &&
          _currentSubtitle != null &&
          newSub == null) {
        int nextIdx = _subtitles.indexWhere((s) => s.start > pos);
        if (nextIdx != -1) {
          _audioPlayer.seek(_subtitles[nextIdx].start);
        }
      }

      _currentSubtitle = newSub;
    }
  }

  Subtitle? _getNearestSubtitle() {
    if (_subtitles.isEmpty) return null;
    Subtitle? last;
    for (Subtitle s in _subtitles) {
      if (_positionNotifier.value < s.start) return last;
      last = s;
    }
    return last;
  }

  void _seekPrev() async {
    if (_subtitles.isEmpty) return;
    int idx = _subtitles.lastIndexWhere(
        (s) => _positionNotifier.value > s.start + const Duration(milliseconds: 500));
    if (idx != -1) {
      _isSeeking = true;
      _currentSubtitle = null;
      _autoPauseMemory = null;
      await _audioPlayer.seek(_subtitles[idx].start);
      _isSeeking = false;
    }
  }

  void _seekNext() async {
    if (_subtitles.isEmpty) return;
    int idx = _subtitles.indexWhere((s) => s.start > _positionNotifier.value);
    if (idx != -1) {
      _isSeeking = true;
      _currentSubtitle = null;
      _autoPauseMemory = null;
      await _audioPlayer.seek(_subtitles[idx].start);
      _isSeeking = false;
    }
  }

  void _replay() async {
    Subtitle? sub = _getNearestSubtitle();
    if (sub != null) {
      _isSeeking = true;
      _currentSubtitle = null;
      _autoPauseMemory = null;
      await _audioPlayer.seek(sub.start);
      _isSeeking = false;
      if (!_audioPlayer.playing) await _audioPlayer.play();
    }
  }

  Future<void> _playPause() async {
    if (_audioPlayer.playing) {
      await _audioPlayer.pause();
    } else {
      _autoPauseMemory = null;
      await _audioPlayer.play();
    }
  }

  Future<void> _pickMp3() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'm4a', 'ogg', 'wav', 'flac', 'aac'],
    );
    if (result != null && result.files.single.path != null) {
      _mp3Path = result.files.single.path!;
      await _loadAudio();
      await _persist();
      _collapsed = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _pickSrt() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['srt'],
    );
    if (result != null && result.files.single.path != null) {
      _srtPath = result.files.single.path!;
      await _loadSubtitles();
      await _persist();
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearAudio() async {
    await _audioPlayer.stop();
    _mp3Path = null;
    _srtPath = null;
    _subtitles = [];
    _currentSubtitle = null;
    _autoPauseMemory = null;
    _audioLoaded = false;
    _collapsed = true;
    String key = _safeKey(widget.bookKey);
    await _box.delete('mp3_$key');
    await _box.delete('srt_$key');
    await _box.delete('pos_$key');
    if (mounted) setState(() {});
  }

  void _showMenu() {
    PlaybackMode mode = widget.appModel.playbackMode;
    Map<PlaybackMode, String> modeLabels = {
      PlaybackMode.normalPlayback: t.playback_normal,
      PlaybackMode.condensedPlayback: t.playback_condensed,
      PlaybackMode.autoPausePlayback: t.playback_auto_pause,
    };
    Map<PlaybackMode, IconData> modeIcons = {
      PlaybackMode.normalPlayback: Icons.play_arrow,
      PlaybackMode.condensedPlayback: Icons.skip_next,
      PlaybackMode.autoPausePlayback: Icons.pause,
    };

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.audiotrack),
              title: Text(_mp3Path != null
                  ? _mp3Path!.split('/').last
                  : 'Select audio file'),
              subtitle: _mp3Path != null ? const Text('Tap to change') : null,
              onTap: () { Navigator.pop(ctx); _pickMp3(); },
            ),
            ListTile(
              leading: const Icon(Icons.subtitles),
              title: Text(_srtPath != null
                  ? _srtPath!.split('/').last
                  : 'Select subtitle file (.srt)'),
              subtitle: _srtPath != null
                  ? Text('${_subtitles.length} lines')
                  : null,
              onTap: () { Navigator.pop(ctx); _pickSrt(); },
            ),
            ListTile(
              leading: const Icon(Icons.speed),
              title: const Text('Playback speed'),
              subtitle: Text('${_audioPlayer.speed.toStringAsFixed(1)}x'),
              onTap: () { Navigator.pop(ctx); _showSpeedDialog(); },
            ),
            ListTile(
              leading: Icon(modeIcons[mode]),
              title: Text(modeLabels[mode] ?? ''),
              subtitle: const Text('Tap to cycle'),
              onTap: () {
                int next = (mode.index + 1) % PlaybackMode.values.length;
                widget.appModel.setPlaybackMode(PlaybackMode.values[next]);
                Navigator.pop(ctx);
                setState(() {});
              },
            ),
            if (_mp3Path != null)
              ListTile(
                leading: const Icon(Icons.clear, color: Colors.red),
                title: const Text('Remove audio',
                    style: TextStyle(color: Colors.red)),
                onTap: () { Navigator.pop(ctx); _clearAudio(); },
              ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: Text(widget.hasSecondary
                  ? (widget.secondaryTitle ?? 'Translation book')
                  : 'Set translation book'),
              subtitle: widget.hasSecondary
                  ? const Text('Tap to change')
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                widget.onOpenSecondaryManager?.call();
              },
            ),
            if (widget.hasSecondary)
              ListTile(
                leading: const Icon(Icons.clear, color: Colors.red),
                title: const Text('Remove translation book',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onRemoveSecondary?.call();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showSpeedDialog() {
    showDialog(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Playback speed'),
        children: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0].map((spd) {
          return SimpleDialogOption(
            onPressed: () {
              _audioPlayer.setSpeed(spd);
              _box.put('playback_speed', spd);
              Navigator.pop(ctx);
              setState(() {});
            },
            child: Text(
              '${spd.toStringAsFixed(2)}x',
              style: TextStyle(
                fontWeight:
                    spd == _audioPlayer.speed ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_collapsed && !_audioLoaded) return _buildCollapsed();
    return _buildExpanded();
  }

  Widget _buildCollapsed() {
    return Container(
      color: Theme.of(context).cardColor.withOpacity(0.9),
      child: SafeArea(
        top: false,
        child: InkWell(
          onTap: _showMenu,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.audiotrack,
                    size: 16, color: Theme.of(context).unselectedWidgetColor),
                const SizedBox(width: 8),
                Text('Set audiobook',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).unselectedWidgetColor)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded() {
    return Container(
      height: 48,
      color: Theme.of(context).cardColor.withOpacity(0.9),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              const SizedBox(width: 4),
              _btn(Icons.fast_rewind, t.seek_control, _seekPrev),
              _btn(Icons.replay, t.replay_subtitle, _replay),
              _buildPlayPause(),
              _btn(Icons.fast_forward, t.seek_control, _seekNext),
              _buildTime(),
              Expanded(child: _buildSlider()),
              _buildSecondaryToggle(),
              _btn(Icons.more_vert, t.show_options, _showMenu),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String tooltip, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: JidoujishoIconButton(size: 24, icon: icon, tooltip: tooltip, onTap: onTap),
    );
  }

  Widget _buildPlayPause() {
    return ValueListenableBuilder<bool>(
      valueListenable: _playingNotifier,
      builder: (_, playing, __) => _btn(
        playing ? Icons.pause : Icons.play_arrow,
        playing ? t.pause : t.play,
        _playPause,
      ),
    );
  }

  Widget _buildSecondaryToggle() {
    return Material(
      color: Colors.transparent,
      child: JidoujishoIconButton(
        size: 24,
        icon: widget.secondaryShown
            ? Icons.chrome_reader_mode
            : Icons.chrome_reader_mode_outlined,
        tooltip: 'Toggle translation book',
        onTap: () {
          if (widget.secondaryShown) {
            widget.onToggleSecondary?.call();
          } else if (widget.hasSecondary) {
            widget.onToggleSecondary?.call();
          } else {
            widget.onOpenSecondaryManager?.call();
          }
        },
      ),
    );
  }

  Widget _buildTime() {
    return MultiValueListenableBuilder(
      valueListenables: [_positionNotifier, _durationNotifier],
      builder: (_, values, __) {
        Duration pos = values.elementAt(0);
        Duration dur = values.elementAt(1);
        if (dur == Duration.zero) return const SizedBox.shrink();
        String p = JidoujishoTimeFormat.getVideoDurationText(pos).trim();
        String d = JidoujishoTimeFormat.getVideoDurationText(dur).trim();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('$p / $d',
              style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).textTheme.bodySmall?.color)),
        );
      },
    );
  }

  Widget _buildSlider() {
    return MultiValueListenableBuilder(
      valueListenables: [_positionNotifier, _durationNotifier],
      builder: (_, values, __) {
        Duration pos = values.elementAt(0);
        Duration dur = values.elementAt(1);
        if (dur == Duration.zero) return const SizedBox.shrink();
        double val = pos.inMilliseconds.toDouble()
            .clamp(0, dur.inMilliseconds.toDouble());
        return SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          ),
          child: Slider(
            value: val,
            max: dur.inMilliseconds.toDouble(),
            onChangeStart: (_) => _sliderBeingDragged = true,
            onChanged: (v) =>
                _positionNotifier.value = Duration(milliseconds: v.toInt()),
            onChangeEnd: (v) {
              _audioPlayer.seek(Duration(milliseconds: v.toInt()));
              _sliderBeingDragged = false;
              _autoPauseMemory = null;
            },
          ),
        );
      },
    );
  }
}
