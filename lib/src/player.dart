/// This file is a part of media_kit (https://github.com/alexmercerind/media_kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:ffi';
import 'dart:async';
import 'dart:isolate';
import 'package:ffi/ffi.dart';

import 'package:libmpv/src/dynamic_library.dart';
import 'package:libmpv/src/core/initializer.dart';
import 'package:libmpv/src/models/media.dart';
import 'package:libmpv/src/models/playlist.dart';
import 'package:libmpv/src/models/playlist_mode.dart';

import 'package:libmpv/generated/bindings.dart' as generated;

import 'package:libmpv/src/plugins/youtube.dart';

/// ## Player
///
/// [Player] class provides high-level interface for media playback.
///
/// ```dart
/// final player = Player();
/// player.open(
///   Playlist(
///     [
///       Media('https://alexmercerind.github.io/music.mp3'),
///       Media('file://C:/documents/video.mp4'),
///     ],
///   ),
/// );
/// player.play();
/// ```
///
class Player {
  /// ## Player
  ///
  /// [Player] class provides high-level interface for media playback.
  ///
  /// ```dart
  /// final player = Player();
  /// player.open(
  ///   Playlist(
  ///     [
  ///       Media('https://alexmercerind.github.io/music.mp3'),
  ///       Media('file://C:/documents/video.mp4'),
  ///     ],
  ///   ),
  /// );
  /// player.play();
  /// ```
  ///
  Player({
    this.video = false,
    this.osc = false,
    this.maxVolume = 200.0,
    bool yt = true,
    this.title,
    void Function()? onCreate,
  }) {
    if (yt) {
      youtube = YouTube();
    }
    _create().then(
      (_) => onCreate?.call(),
    );
  }

  /// Current state of the [Player]. For listening to these values and events, use [Player.streams] instead.
  _PlayerState state = _PlayerState();

  /// Various event streams to listen to events of a [Player].
  ///
  /// ```dart
  /// final player = Player();
  /// player.position.listen((position) {
  ///   print(position.inMilliseconds);
  /// });
  /// ```
  ///
  /// There are a lot of events like [isPlaying], [medias], [index] etc. to listen to & cause UI re-build.
  ///
  late _PlayerStreams streams;

  /// MPV handle of the internal instance.
  Pointer<generated.mpv_handle> get handle => _handle;

  /// Disposes the [Player] instance & releases the resources.
  Future<void> dispose({int code = 0}) async {
    await _completer.future;
    // Raw `mpv_command` calls cause crash on Windows.
    final args = [
      'quit',
      '$code',
    ].join(' ').toNativeUtf8();
    mpv.mpv_command_string(
      _handle,
      args.cast(),
    );
    _playlistController.close();
    _isPlayingController.close();
    _isCompletedController.close();
    _positionController.close();
    _durationController.close();
    youtube?.close();
  }

  /// Opens a [List] of [Media]s into the [Player] as a playlist.
  /// Previously opened, added or inserted [Media]s get removed.
  ///
  /// ```dart
  /// player.open(
  ///   Playlist(
  ///     [
  ///       Media('https://alexmercerind.github.io/music.mp3'),
  ///       Media('file://C:/documents/video.mp4'),
  ///     ],
  ///   ),
  /// );
  /// ```
  Future<void> open(
    Playlist playlist, {
    bool play = true,
  }) async {
    // Clean-up existing cached [medias].
    medias.clear();
    // Restore current playlist.
    for (final media in playlist.medias) {
      medias[() {
        // Match with format retrieved by `mpv_get_property`.
        if (media.uri.startsWith('file')) {
          return Uri.parse(media.uri).toFilePath().replaceAll('\\', '/');
        } else {
          return media.uri;
        }
      }()] = media;
    }
    await _completer.future;
    _command(
      [
        'playlist-play-index',
        'none',
      ],
    );
    _command(
      [
        'playlist-clear',
      ],
    );
    for (final media in playlist.medias) {
      _command(
        [
          'loadfile',
          media.uri,
          'append',
        ],
      );
    }
    // Even though `replace` parameter in `loadfile` automatically causes the
    // [Media] to play but in certain cases like, where a [Media] is paused & then
    // new [Media] is [Player.open]ed it causes [Media] to not starting playing
    // automatically.
    // Thanks to <github.com/DomingoMG> for the fix!
    state.playlist = playlist;
    // To wait for the index change [jump] call.
    if (!play) {
      pause();
    }
    if (!_playlistController.isClosed) {
      _playlistController.add(state.playlist);
    }
    await jump(playlist.index, play: play);
  }

  /// Starts playing the [Player].
  Future<void> play() async {
    await _completer.future;
    var name = 'playlist-pos-1'.toNativeUtf8();
    final pos = calloc<Int64>();
    mpv.mpv_get_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_INT64,
      pos.cast(),
    );
    if ((pos.value <= 0 ||
            (pos.value == 1 && state.position == Duration.zero) ||
            state.isCompleted) &&
        _isPlaybackEverStarted) {
      jump(0);
    }
    calloc.free(name);
    _isPlaybackEverStarted = true;
    name = 'pause'.toNativeUtf8();
    final flag = calloc<Int8>();
    flag.value = 0;
    mpv.mpv_set_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_FLAG,
      flag.cast(),
    );
    calloc.free(name);
    calloc.free(flag);
  }

  /// Pauses the [Player].
  Future<void> pause() async {
    await _completer.future;
    final name = 'pause'.toNativeUtf8();
    final flag = calloc<Int8>();
    flag.value = 1;
    mpv.mpv_set_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_FLAG,
      flag.cast(),
    );
    calloc.free(name);
    calloc.free(flag);
  }

  /// Appends a [Media] to the [Player]'s playlist.
  Future<void> add(Media media) async {
    await _completer.future;
    _command(
      [
        'loadfile',
        media.uri,
        'append',
        null,
      ],
    );
    state.playlist.medias.add(media);
    if (!_playlistController.isClosed) {
      _playlistController.add(state.playlist);
    }
  }

  /// Removes the [Media] at specified index from the [Player]'s playlist.
  Future<void> remove(int index) async {
    await _completer.future;
    _command(
      [
        'playlist-remove',
        index.toString(),
      ],
    );
    state.playlist.medias.removeAt(index);
    if (!_playlistController.isClosed) {
      _playlistController.add(state.playlist);
    }
  }

  /// Jumps to next [Media] in the [Player]'s playlist.
  Future<void> next() async {
    await _completer.future;
    _command(
      [
        'playlist-next',
      ],
    );
    _isPlaybackEverStarted = true;
    final name = 'pause'.toNativeUtf8();
    final flag = calloc<Int8>();
    flag.value = 0;
    mpv.mpv_set_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_FLAG,
      flag.cast(),
    );
    calloc.free(name);
    calloc.free(flag);
  }

  /// Jumps to previous [Media] in the [Player]'s playlist.
  Future<void> back() async {
    await _completer.future;
    _command(
      [
        'playlist-prev',
      ],
    );
    _isPlaybackEverStarted = true;
    final name = 'pause'.toNativeUtf8();
    final flag = calloc<Int8>();
    flag.value = 0;
    mpv.mpv_set_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_FLAG,
      flag.cast(),
    );
    calloc.free(name);
    calloc.free(flag);
  }

  /// Jumps to specified [Media]'s index in the [Player]'s playlist.
  Future<void> jump(
    int index, {
    bool play = true,
  }) async {
    await _completer.future;
    state.playlist.index = index;
    if (!_playlistController.isClosed) {
      _playlistController.add(state.playlist);
    }
    var name = 'playlist-pos-1'.toNativeUtf8();
    final value = calloc<Int64>()..value = index + 1;
    mpv.mpv_set_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_INT64,
      value.cast(),
    );
    calloc.free(name);
    if (!play) {
      return;
    }
    _isPlaybackEverStarted = true;
    name = 'pause'.toNativeUtf8();
    final flag = calloc<Int8>();
    flag.value = 0;
    mpv.mpv_set_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_FLAG,
      flag.cast(),
    );
    calloc.free(name);
    calloc.free(flag);
    calloc.free(value);
  }

  /// Moves the playlist [Media] at [from], so that it takes the place of the [Media] [to].
  Future<void> move(int from, int to) async {
    await _completer.future;
    _command(
      [
        'playlist-move',
        from.toString(),
        to.toString(),
      ],
    );
    state.playlist.medias.insert(to, state.playlist.medias.removeAt(from));
    _playlistController.add(state.playlist);
  }

  /// Seeks the currently playing [Media] in the [Player] by specified [Duration].
  Future<void> seek(Duration duration) async {
    await _completer.future;
    // Raw `mpv_command` calls cause crash on Windows.
    final args = [
      'seek',
      (duration.inMilliseconds / 1000).toStringAsFixed(4).toString(),
      'absolute',
    ].join(' ').toNativeUtf8();
    mpv.mpv_command_string(
      _handle,
      args.cast(),
    );
    calloc.free(args);
  }

  /// Sets playlist mode.
  Future<void> setPlaylistMode(PlaylistMode playlistMode) async {
    await _completer.future;
    final loopFile = 'loop-file'.toNativeUtf8();
    final loopPlaylist = 'loop-playlist'.toNativeUtf8();
    final yes = calloc<Int8>();
    yes.value = 1;
    final no = calloc<Int8>();
    no.value = 0;
    switch (playlistMode) {
      case PlaylistMode.none:
        {
          mpv.mpv_set_property(
            handle,
            loopFile.cast(),
            generated.mpv_format.MPV_FORMAT_FLAG,
            no.cast(),
          );
          mpv.mpv_set_property(
            handle,
            loopPlaylist.cast(),
            generated.mpv_format.MPV_FORMAT_FLAG,
            no.cast(),
          );
          break;
        }
      case PlaylistMode.single:
        {
          mpv.mpv_set_property(
            handle,
            loopFile.cast(),
            generated.mpv_format.MPV_FORMAT_FLAG,
            yes.cast(),
          );
          mpv.mpv_set_property(
            handle,
            loopPlaylist.cast(),
            generated.mpv_format.MPV_FORMAT_FLAG,
            no.cast(),
          );
          break;
        }
      case PlaylistMode.loop:
        {
          mpv.mpv_set_property(
            handle,
            loopFile.cast(),
            generated.mpv_format.MPV_FORMAT_FLAG,
            no.cast(),
          );
          mpv.mpv_set_property(
            handle,
            loopPlaylist.cast(),
            generated.mpv_format.MPV_FORMAT_FLAG,
            yes.cast(),
          );
          break;
        }
      default:
        break;
    }
    calloc.free(loopFile);
    calloc.free(loopPlaylist);
    calloc.free(yes);
    calloc.free(no);
  }

  /// Sets the playback volume of the [Player]. Defaults to `100.0`.
  set volume(double volume) {
    () async {
      await _completer.future;
      final name = 'volume'.toNativeUtf8();
      final value = calloc<Double>();
      value.value = volume;
      mpv.mpv_set_property(
        _handle,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_DOUBLE,
        value.cast(),
      );
      calloc.free(name);
      calloc.free(value);
    }();
  }

  /// Sets the playback rate of the [Player]. Defaults to `1.0`.
  /// Resets [pitch] to `1.0`.
  set rate(double rate) {
    () async {
      await _completer.future;
      state.rate = rate;
      if (!_rateController.isClosed) {
        _rateController.add(state.rate);
      }
      // No `rubberband` is available.
      // Apparently, using `scaletempo:scale` actually controls the playback rate
      // as intended after setting `audio-pitch-correction` as `FALSE`.
      // `speed` on the other hand, changes the pitch when `audio-pitch-correction`
      // is set to `FALSE`. Since, it also alters the actual [speed], the
      // `scaletempo:scale` is divided by the same value of [pitch] to compensate the
      // speed change.
      var name = 'audio-pitch-correction'.toNativeUtf8();
      final flag = calloc<Int8>()..value = 0;
      mpv.mpv_set_property(
        _handle,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_FLAG,
        flag.cast(),
      );
      calloc.free(name);
      calloc.free(flag);
      name = 'af'.toNativeUtf8();
      // Divide by [state.pitch] to compensate the speed change caused by pitch shift.
      final value =
          'scaletempo:scale=${(state.rate / state.pitch).toStringAsFixed(8)}'
              .toNativeUtf8();
      mpv.mpv_set_property_string(
        _handle,
        name.cast(),
        value.cast(),
      );
      print(value.toDartString());
      calloc.free(name);
      calloc.free(value);
    }();
  }

  /// Sets the relative pitch of the [Player]. Defaults to `1.0`.
  set pitch(double pitch) {
    () async {
      await _completer.future;
      state.pitch = pitch;
      if (!_pitchController.isClosed) {
        _pitchController.add(state.pitch);
      }
      // `rubberband` is not bundled in `libmpv` shared library at the moment.
      // Using `scaletempo` instead. However, this comes with a drackback
      // that speed & pitch cannot be changed simultaneously.
      // final name = 'af'.toNativeUtf8();
      // final keys = calloc<Pointer<Utf8>>(2);
      // final paramKeys = calloc<Pointer<Utf8>>(2);
      // final paramValues = calloc<Pointer<Utf8>>(2);
      // paramKeys[0] = 'key'.toNativeUtf8();
      // paramKeys[1] = 'value'.toNativeUtf8();
      // paramValues[0] = 'pitch-scale'.toNativeUtf8();
      // paramValues[1] = pitch.toStringAsFixed(8).toNativeUtf8();
      // final values = calloc<Pointer<generated.mpv_node>>(2);
      // keys[0] = 'name'.toNativeUtf8();
      // keys[1] = 'params'.toNativeUtf8();
      // values[0] = calloc<generated.mpv_node>();
      // values[0].ref.format = generated.mpv_format.MPV_FORMAT_STRING;
      // values[0].ref.u.string = 'rubberband'.toNativeUtf8().cast();
      // values[1] = calloc<generated.mpv_node>();
      // values[1].ref.format = generated.mpv_format.MPV_FORMAT_NODE_MAP;
      // values[1].ref.u.list = calloc<generated.mpv_node_list>();
      // values[1].ref.u.list.ref.num = 2;
      // values[1].ref.u.list.ref.keys = paramKeys.cast();
      // values[1].ref.u.list.ref.values = paramValues.cast();
      // final data = calloc<generated.mpv_node>();
      // data.ref.format = generated.mpv_format.MPV_FORMAT_NODE_ARRAY;
      // data.ref.u.list = calloc<generated.mpv_node_list>();
      // data.ref.u.list.ref.num = 1;
      // data.ref.u.list.ref.values = calloc<generated.mpv_node>();
      // data.ref.u.list.ref.values.ref.format =
      //     generated.mpv_format.MPV_FORMAT_NODE_MAP;
      // data.ref.u.list.ref.values.ref.u.list = calloc<generated.mpv_node_list>();
      // data.ref.u.list.ref.values.ref.u.list.ref.num = 2;
      // data.ref.u.list.ref.values.ref.u.list.ref.keys = keys.cast();
      // data.ref.u.list.ref.values.ref.u.list.ref.values = values.cast();
      // mpv.mpv_set_property(
      //   _handle,
      //   name.cast(),
      //   generated.mpv_format.MPV_FORMAT_NODE,
      //   data.cast(),
      // );
      // calloc.free(name);
      // mpv.mpv_free_node_contents(data);
      var name = 'audio-pitch-correction'.toNativeUtf8();
      final flag = calloc<Int8>()..value = 0;
      mpv.mpv_set_property(
        _handle,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_FLAG,
        flag.cast(),
      );
      calloc.free(name);
      calloc.free(flag);
      name = 'speed'.toNativeUtf8();
      final speed = calloc<Double>()..value = pitch;
      mpv.mpv_set_property(
        _handle,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_DOUBLE,
        speed.cast(),
      );
      calloc.free(name);
      calloc.free(speed);
      name = 'af'.toNativeUtf8();
      // Divide by [state.pitch] to compensate the speed change caused by pitch shift.
      final value =
          'scaletempo:scale=${(state.rate / state.pitch).toStringAsFixed(8)}'
              .toNativeUtf8();
      mpv.mpv_set_property_string(
        _handle,
        name.cast(),
        value.cast(),
      );
      print(value.toDartString());
      calloc.free(name);
      calloc.free(value);
    }();
  }

  /// Enables or disables shuffle for [Player]. Default is `false`.
  set shuffle(bool shuffle) {
    () async {
      await _completer.future;
      _command(
        [
          shuffle ? 'playlist-shuffle' : 'playlist-unshuffle',
        ],
      );
      final name = 'playlist'.toNativeUtf8();
      final data = calloc<generated.mpv_node>();
      mpv.mpv_get_property(
        handle,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_NODE,
        data.cast(),
      );
      try {
        // Shuffling updates the order of [state.playlist]. Fetching latest playlist from MPV & updating Dart stream.
        if (data.ref.format == generated.mpv_format.MPV_FORMAT_NODE_ARRAY) {
          final playlist = <Media>[];
          for (int i = 0; i < data.ref.u.list.ref.num; i++) {
            if (data.ref.u.list.ref.values[i].format ==
                generated.mpv_format.MPV_FORMAT_NODE_MAP) {
              for (int j = 0;
                  j < data.ref.u.list.ref.values[i].u.list.ref.num;
                  j++) {
                if (data.ref.u.list.ref.values[i].u.list.ref.values[j].format ==
                    generated.mpv_format.MPV_FORMAT_STRING) {
                  final property = data
                      .ref.u.list.ref.values[i].u.list.ref.keys[j]
                      .cast<Utf8>()
                      .toDartString();
                  if (property == 'filename') {
                    final value = data
                        .ref.u.list.ref.values[i].u.list.ref.values[j].u.string
                        .cast<Utf8>()
                        .toDartString();
                    playlist.add(medias[value]!);
                  }
                }
              }
            }
          }
          state.playlist.medias = playlist;
          if (!_playlistController.isClosed) {
            _playlistController.add(state.playlist);
          }
          calloc.free(name);
          calloc.free(data);
        }
      } catch (exception, stacktrace) {
        print(exception);
        print(stacktrace);
        _command(
          [
            'playlist-unshuffle',
          ],
        );
      }
    }();
  }

  Future<void> _create() async {
    if (libmpv == null) return;
    streams = _PlayerStreams(
      _playlistController.stream,
      _isPlayingController.stream,
      _isCompletedController.stream,
      _positionController.stream,
      _durationController.stream,
      _volumeController.stream,
      _rateController.stream,
      _pitchController.stream,
      _isBufferingController.stream,
      _errorController.stream,
    );
    _handle = await create(
      libmpv!,
      (event) async {
        _error(event.ref.error);
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_START_FILE) {
          state.isCompleted = false;
          if (_isPlaybackEverStarted) {
            state.isPlaying = true;
          }
          if (!_isCompletedController.isClosed) {
            _isCompletedController.add(false);
          }
          if (!_isPlayingController.isClosed && _isPlaybackEverStarted) {
            _isPlayingController.add(true);
          }
        }
        if (event.ref.event_id == generated.mpv_event_id.MPV_EVENT_END_FILE) {
          // Check for `mpv_end_file_reason.MPV_END_FILE_REASON_EOF` before
          // modifying `state.isCompleted`.
          // Thanks to <github.com/DomingoMG> for noticing the bug.
          if (event.ref.data.cast<generated.mpv_event_end_file>().ref.reason ==
              generated.mpv_end_file_reason.MPV_END_FILE_REASON_EOF) {
            state.isCompleted = true;
            if (_isPlaybackEverStarted) {
              state.isPlaying = false;
            }
            if (!_isCompletedController.isClosed) {
              _isCompletedController.add(true);
            }
            if (!_isPlayingController.isClosed && _isPlaybackEverStarted) {
              _isPlayingController.add(false);
            }
          }
        }
        if (event.ref.event_id ==
            generated.mpv_event_id.MPV_EVENT_PROPERTY_CHANGE) {
          final prop = event.ref.data.cast<generated.mpv_event_property>();
          if (prop.ref.name.cast<Utf8>().toDartString() == 'pause' &&
              prop.ref.format == generated.mpv_format.MPV_FORMAT_FLAG) {
            if (_isPlaybackEverStarted) {
              final isPlaying = prop.ref.data.cast<Int8>().value != 1;
              state.isPlaying = isPlaying;
              if (!_isPlayingController.isClosed) {
                _isPlayingController.add(isPlaying);
              }
            }
          }
          if (prop.ref.name.cast<Utf8>().toDartString() == 'paused-for-cache' &&
              prop.ref.format == generated.mpv_format.MPV_FORMAT_FLAG) {
            final isBuffering = prop.ref.data.cast<Int8>().value != 0;
            state.isBuffering = isBuffering;
            if (!_isBufferingController.isClosed) {
              _isBufferingController.add(isBuffering);
            }
          }
          if (prop.ref.name.cast<Utf8>().toDartString() == 'time-pos' &&
              prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
            final position = Duration(
                microseconds: prop.ref.data.cast<Double>().value * 1e6 ~/ 1);
            state.position = position;
            if (!_positionController.isClosed) {
              _positionController.add(position);
            }
          }
          if (prop.ref.name.cast<Utf8>().toDartString() == 'duration' &&
              prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
            final duration = Duration(
                microseconds: prop.ref.data.cast<Double>().value * 1e6 ~/ 1);
            state.duration = duration;
            if (!_durationController.isClosed) {
              _durationController.add(duration);
            }
          }
          if (prop.ref.name.cast<Utf8>().toDartString() == 'playlist-pos-1' &&
              prop.ref.format == generated.mpv_format.MPV_FORMAT_INT64) {
            final index = prop.ref.data.cast<Int64>().value - 1;
            if (_isPlaybackEverStarted) {
              state.playlist.index = index;
              if (!_playlistController.isClosed) {
                _playlistController.add(state.playlist);
              }
            }
          }
          if (prop.ref.name.cast<Utf8>().toDartString() == 'volume' &&
              prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
            final volume = prop.ref.data.cast<Double>().value;
            state.volume = volume;
            if (!_volumeController.isClosed) {
              _volumeController.add(volume);
            }
          }
          // See [rate] & [pitch] setters.
          // Handled manually using `scaletempo`.
          // if (prop.ref.name.cast<Utf8>().toDartString() == 'speed' &&
          //     prop.ref.format == generated.mpv_format.MPV_FORMAT_DOUBLE) {
          //   final rate = prop.ref.data.cast<Double>().value;
          //   state.rate = rate;
          //   if (!_rateController.isClosed) {
          //     _rateController.add(rate);
          //   }
          // }
        }
      },
    );
    final properties = <String, int>{
      'pause': generated.mpv_format.MPV_FORMAT_FLAG,
      'time-pos': generated.mpv_format.MPV_FORMAT_DOUBLE,
      'duration': generated.mpv_format.MPV_FORMAT_DOUBLE,
      'playlist-pos-1': generated.mpv_format.MPV_FORMAT_INT64,
      'seekable': generated.mpv_format.MPV_FORMAT_FLAG,
      'volume': generated.mpv_format.MPV_FORMAT_DOUBLE,
      'speed': generated.mpv_format.MPV_FORMAT_DOUBLE,
      'paused-for-cache': generated.mpv_format.MPV_FORMAT_FLAG,
    };
    properties.forEach((property, format) {
      final ptr = property.toNativeUtf8();
      mpv.mpv_observe_property(
        _handle,
        0,
        ptr.cast(),
        format,
      );
      calloc.free(ptr);
    });
    // No longer explicitly setting demuxer cache size.
    // Though, it may cause rise in memory usage but still it is certainly better
    // than files randomly stuttering or seeking to a random position on their own.
    // <String, int>{
    //   'demuxer-max-bytes': 8192000,
    //   'demuxer-max-back-bytes': 8192000,
    // }.forEach((key, value) {
    //   final _key = key.toNativeUtf8();
    //   final _value = calloc<Int64>()..value = value;
    //   mpv.mpv_set_property(
    //     _handle,
    //     _key.cast(),
    //     generated.mpv_format.MPV_FORMAT_INT64,
    //     _value.cast(),
    //   );
    //   calloc.free(_key);
    //   calloc.free(_value);
    // });
    if (!video) {
      final vo = 'vo'.toNativeUtf8();
      final osd = 'osd'.toNativeUtf8();
      final value = 'null'.toNativeUtf8();
      mpv.mpv_set_property_string(
        _handle,
        vo.cast(),
        value.cast(),
      );
      mpv.mpv_set_property_string(
        _handle,
        osd.cast(),
        value.cast(),
      );
      calloc.free(vo);
      calloc.free(osd);
      calloc.free(value);
    }
    if (osc) {
      final name = 'osc'.toNativeUtf8();
      Pointer<Int8> flag = calloc<Int8>()..value = 1;
      mpv.mpv_set_option(
        _handle,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_FLAG,
        flag.cast(),
      );
      calloc.free(name);
      calloc.free(flag);
    }
    if (title != null) {
      final name = 'title'.toNativeUtf8();
      final value = title!.toNativeUtf8();
      mpv.mpv_set_property_string(
        _handle,
        name.cast(),
        value.cast(),
      );
      calloc.free(name);
      calloc.free(value);
    }
    // No longer explicitly setting demuxer cache size.
    // Though, it may cause rise in memory usage but still it is certainly better
    // than files randomly stuttering or seeking to a random position on their own.
    // final cache = 'cache'.toNativeUtf8();
    // final no = 'no'.toNativeUtf8();
    // mpv.mpv_set_property_string(
    //   _handle,
    //   cache.cast(),
    //   no.cast(),
    // );
    // calloc.free(cache);
    // calloc.free(no);
    final name = 'volume-max'.toNativeUtf8();
    final value = calloc<Double>()..value = maxVolume.toDouble();
    mpv.mpv_set_property(
      _handle,
      name.cast(),
      generated.mpv_format.MPV_FORMAT_DOUBLE,
      value.cast(),
    );
    _completer.complete();
  }

  /// Adds an error to the [Player.stream.error].
  void _error(int code) {
    if (code < 0 && !_errorController.isClosed) {
      _errorController.add(
        _PlayerError(
          code,
          mpv.mpv_error_string(code).cast<Utf8>().toDartString(),
        ),
      );
    }
  }

  /// Calls MPV command passed as [args]. Automatically freeds memory after command sending.
  ///
  /// An [Isolate] is used to prevent blocking of the main thread during native-type marshalling.
  void _command(List<String?> args) {
    final List<Pointer<Utf8>> pointers = args.map<Pointer<Utf8>>((e) {
      if (e == null) return nullptr.cast();
      return e.toNativeUtf8();
    }).toList();
    final Pointer<Pointer<Utf8>> arr = calloc.allocate(args.join().length);
    for (int i = 0; i < args.length; i++) {
      arr[i] = pointers[i];
    }
    mpv.mpv_command(
      _handle,
      arr.cast(),
    );
    calloc.free(arr);
    pointers.forEach(calloc.free);
  }

  /// Whether video is visible or not.
  final bool video;

  /// Whether on screen controls are visible or not.
  final bool osc;

  /// User defined window title for the MPV instance.
  final String? title;

  /// Maximum volume that can be assigned to this [Player].
  /// Used for volume boost.
  final double maxVolume;

  /// YouTube daemon to serve links.
  YouTube? youtube;

  /// [Pointer] to [generated.mpv_handle] of this instance.
  late Pointer<generated.mpv_handle> _handle;

  /// libmpv API hack, to prevent [state.isPlaying] getting changed due to volume or rate being changed.
  bool _isPlaybackEverStarted = false;

  /// [Completer] used to ensure initialization of [generated.mpv_handle] & synchronization on another isolate.
  final Completer<void> _completer = Completer();

  /// Internally used [StreamController].
  final StreamController<Playlist> _playlistController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<bool> _isPlayingController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<bool> _isCompletedController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<Duration> _positionController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<Duration> _durationController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<double> _volumeController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<double> _rateController = StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<double> _pitchController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<bool> _isBufferingController =
      StreamController.broadcast();

  /// Internally used [StreamController].
  final StreamController<_PlayerError> _errorController =
      StreamController.broadcast();
}

/// Private class to raise errors by the [Player].
class _PlayerError {
  final int id;
  final String message;

  _PlayerError(this.id, this.message);
}

/// Private class to keep state of the [Player].
class _PlayerState {
  /// [List] of currently opened [Media]s.
  Playlist playlist = Playlist([]);

  /// If the [Player] is playing.
  bool isPlaying = false;

  /// If the [Player]'s playback is completed.
  bool isCompleted = false;

  /// Current playback position of the [Player].
  Duration position = Duration.zero;

  /// Duration of the currently playing [Media] in the [Player].
  Duration duration = Duration.zero;

  /// Current volume of the [Player].
  double volume = 1.0;

  /// Current playback rate of the [Player].
  double rate = 1.0;

  /// Current pitch of the [Player].
  double pitch = 1.0;

  /// Whether the [Player] has stopped for buffering.
  bool isBuffering = false;
}

/// Private class for event handling of [Player].
class _PlayerStreams {
  /// [List] of currently opened [Media]s.
  late Stream<Playlist> playlist;

  /// If the [Player] is playing.
  late Stream<bool> isPlaying;

  /// If the [Player]'s playback is completed.
  late Stream<bool> isCompleted;

  /// Current playback position of the [Player].
  late Stream<Duration> position;

  /// Duration of the currently playing [Media] in the [Player].
  late Stream<Duration> duration;

  /// Current volume of the [Player].
  late Stream<double> volume;

  /// Current playback rate of the [Player].
  late Stream<double> rate;

  /// Current pitch of the [Player].
  late Stream<double> pitch;

  /// Whether the [Player] has stopped for buffering.
  late Stream<bool> isBuffering;

  /// [Stream] raising [_PlayerError]s.
  late Stream<_PlayerError> error;

  _PlayerStreams(
    this.playlist,
    this.isPlaying,
    this.isCompleted,
    this.position,
    this.duration,
    this.volume,
    this.rate,
    this.pitch,
    this.isBuffering,
    this.error,
  );
}
