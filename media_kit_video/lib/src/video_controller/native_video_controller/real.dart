/// This file is a part of media_kit (https://github.com/alexmercerind/media_kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template native_video_controller}
///
/// NativeVideoController
/// ---------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on:
/// * Windows
/// * GNU/Linux
/// * macOS
/// * iOS
///
/// {@endtemplate}
class NativeVideoController extends PlatformVideoController {
  /// Whether [NativeVideoController] is supported on the current platform or not.
  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;
  bool playing = false;

  /// {@macro native_video_controller}
  NativeVideoController._(
    super.player,
    super.width,
    super.height,
    super.enableHardwareAcceleration,
  ) {
    player.streams.playing.listen((e) async {
      refreshPlaybackState();
    });

    player.streams.duration.listen((e) async {
      refreshPlaybackState();
    });

    player.streams.seek.listen((e) async {
      refreshPlaybackState();
    });
  }

  /// {@macro native_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    int? width,
    int? height,
    bool enableHardwareAcceleration,
  ) async {
    // Retrieve the native handle of the [Player].
    final handle = await player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = NativeVideoController._(
      player,
      width,
      height,
      enableHardwareAcceleration,
    );
    // Register [_dispose] for execution upon [Player.dispose].
    player.platform?.release.add(controller._dispose);

    // Store the [NativeVideoController] in the [_controllers].
    _controllers[handle] = controller;

    // Wait until first texture ID is received i.e. render context & EGL/D3D surface is created.
    // We are not waiting on the native-side itself because it will block the UI thread.
    // Background platform channels are not a thing yet.
    final completer = Completer<void>();
    void listener() {
      if (controller.id.value != null) {
        debugPrint('NativeVideoController: Texture ID: ${controller.id.value}');
        completer.complete();
      }
    }

    controller.id.addListener(listener);

    await _channel.invokeMethod(
      'VideoOutputManager.Create',
      {
        'handle': handle.toString(),
        'width': width.toString(),
        'height': height.toString(),
        'enableHardwareAcceleration': enableHardwareAcceleration,
      },
    );

    await completer.future;
    controller.id.removeListener(listener);

    // Return the [VideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void> setSize({
    int? width,
    int? height,
  }) async {
    final handle = await player.handle;
    if (this.width == width && this.height == height) {
      // No need to resize if the requested size is same as the current size.
      return;
    }
    this.width = width;
    this.height = height;
    await _channel.invokeMethod(
      'VideoOutputManager.SetSize',
      {
        'handle': handle.toString(),
        'width': width.toString(),
        'height': height.toString(),
      },
    );
  }

  /// Refreshes playback state (on play/pause, seek or duration change).
  /// Used to invalidate Picture in Picture view data.
  @override
  Future<void> refreshPlaybackState() async {
    final handle = await player.handle;
    await _channel.invokeMethod(
      'VideoOutputManager.RefreshPlaybackState',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Checks whether Picture in Picture is available on current platform.
  @override
  Future<bool> isPictureInPictureAvailable() async {
    final handle = await player.handle;
    return await _channel.invokeMethod(
      'VideoOutputManager.IsPictureInPictureAvailable',
      {},
    );
  }

  /// Enable Picture in Picture.
  /// Returns true if this is supported on current platofrm.
  Future<bool> enablePictureInPicture() async {
    final handle = await player.handle;
    return await _channel.invokeMethod(
      'VideoOutputManager.EnablePictureInPicture',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Disable Picture in Picture.
  Future<void> disablePictureInPicture() async {
    final handle = await player.handle;
    return await _channel.invokeMethod(
      'VideoOutputManager.DisablePictureInPicture',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Enable automatically entering Picture in Picture when app goes into background.
  /// Returns true if this is supported on current platofrm.
  @override
  Future<bool> enableAutoPictureInPicture() async {
    final handle = await player.handle;
    return await _channel.invokeMethod(
      'VideoOutputManager.EnableAutoPictureInPicture',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Disables automatically entering Picture in Picture when app goes into background.
  @override
  Future<void> disableAutoPictureInPicture() async {
    final handle = await player.handle;
    await _channel.invokeMethod(
      'VideoOutputManager.DisableAutoPictureInPicture',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Enters Picture in Picture view for current video.
  @override
  Future<bool> enterPictureInPicture() async {
    final handle = await player.handle;
    return await _channel.invokeMethod(
      'VideoOutputManager.EnterPictureInPicture',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() async {
    final handle = await player.handle;
    _controllers.remove(handle);
    await _channel.invokeMethod(
      'VideoOutputManager.Dispose',
      {
        'handle': handle.toString(),
      },
    );
  }

  /// Currently created [NativeVideoController]s.
  /// This is used to notify about updated texture IDs & [Rect]s through [channel].
  static final _controllers = HashMap<int, NativeVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler(
          (MethodCall call) async {
            try {
              debugPrint(call.method.toString());
              debugPrint(call.arguments.toString());
              switch (call.method) {
                case 'VideoOutput.Resize':
                  {
                    // Notify about updated texture ID & [Rect].
                    final int handle = call.arguments['handle'];
                    final Rect rect = Rect.fromLTWH(
                      call.arguments['rect']['left'] * 1.0,
                      call.arguments['rect']['top'] * 1.0,
                      call.arguments['rect']['width'] * 1.0,
                      call.arguments['rect']['height'] * 1.0,
                    );
                    final int id = call.arguments['id'];
                    _controllers[handle]?.rect.value = rect;
                    _controllers[handle]?.id.value = id;
                    // Notify about the first frame being rendered.
                    if (rect.width > 0 && rect.height > 0) {
                      final completer = _controllers[handle]
                          ?.waitUntilFirstFrameRenderedCompleter;
                      if (!(completer?.isCompleted ?? true)) {
                        completer?.complete();
                      }
                    }
                    break;
                  }
                default:
                  {
                    break;
                  }
              }
            } catch (exception, stacktrace) {
              debugPrint(exception.toString());
              debugPrint(stacktrace.toString());
            }
          },
        );
}
