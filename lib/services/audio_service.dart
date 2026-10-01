import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:torch_light/torch_light.dart';
import 'package:vibration/vibration.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background audio monitoring service for "Clap to Find Phone".
/// Manages background isolate execution, acoustic spike detection,
/// and coordinated alarm, strobe, and vibration actuation.
class AudioServiceManager {
  static const String notificationChannelId = 'clap_detector_channel';
  static const int notificationId = 888;

  /// Initializes the background service with platform-specific execution parameters.
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'Clap to Find Active',
        initialNotificationContent: 'Acoustic background monitor is listening...',
        foregroundServiceNotificationId: notificationId,
        foregroundServiceTypes: [
          AndroidForegroundType.microphone,
        ],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  /// iOS background isolate callback
  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }
}

/// Entry point executed inside the isolated background service thread.
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Bring up hardware controllers inside isolate
  final AudioRecorder recorder = AudioRecorder();
  final AudioPlayer audioPlayer = AudioPlayer();

  bool isAlerting = false;
  Timer? amplitudePollTimer;
  Timer? strobeTimer;
  bool strobeState = false;

  // Clap detection calibration parameters
  // Audio amplitude in dBFS usually ranges from -60 dB (silence) to 0 dB (max).
  double sensitivityThresholdDb = -16.0; // Higher = requires louder clap
  double ambientBaselineDb = -45.0;
  DateTime lastTriggerTime = DateTime.fromMillisecondsSinceEpoch(0);
  const Duration triggerCooldown = Duration(milliseconds: 2500);

  // Load persisted user preferences
  final prefs = await SharedPreferences.getInstance();
  final savedSensitivity = prefs.getDouble('sensitivity_threshold_db');
  if (savedSensitivity != null) {
    sensitivityThresholdDb = savedSensitivity;
  }

  // Update notification helper for Android
  void updateAndroidNotification(String title, String content) {
    if (service is AndroidServiceInstance) {
      service.setForegroundNotificationInfo(
        title: title,
        content: content,
      );
    }
  }

  /// Stops siren, vibration, and flashlight strobe
  Future<void> stopAlert() async {
    isAlerting = false;
    strobeTimer?.cancel();
    strobeTimer = null;

    try {
      await TorchLight.disableTorch();
    } catch (_) {}

    try {
      await Vibration.cancel();
    } catch (_) {}

    try {
      await audioPlayer.stop();
    } catch (_) {}

    updateAndroidNotification(
      'Clap to Find Active',
      'Listening for acoustic claps...',
    );

    service.invoke('alertStateChanged', {'isAlerting': false});
  }

  /// Activates siren, vibration haptics, and flashlight strobe
  Future<void> triggerAlert(double detectedDb) async {
    if (isAlerting) return;
    isAlerting = true;
    lastTriggerTime = DateTime.now();

    updateAndroidNotification(
      '⚠️ Phone Located!',
      'Clap detected (${detectedDb.toStringAsFixed(1)} dB). Ringing device...',
    );

    service.invoke('alertTriggered', {
      'detectedDb': detectedDb,
      'timestamp': DateTime.now().toIso8601String(),
    });

    // 1. Play loop siren alarm at maximum volume
    try {
      await audioPlayer.setReleaseMode(ReleaseMode.loop);
      await audioPlayer.setVolume(1.0);
      await audioPlayer.play(AssetSource('sounds/alarm_siren.mp3'));
    } catch (e) {
      debugPrint('[AudioService] Audio playback error: $e');
    }

    // 2. Start repeating vibration pattern: [Wait, Vibrate, Wait, Vibrate...]
    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (hasVibrator == true) {
        await Vibration.vibrate(
          pattern: [500, 250, 500, 250, 750, 250],
          intensities: [128, 255, 128, 255, 255, 255],
          repeat: 0,
        );
      }
    } catch (e) {
      debugPrint('[AudioService] Vibration error: $e');
    }

    // 3. Flashlight Strobe Loop (150ms interval)
    try {
      strobeTimer?.cancel();
      strobeTimer = Timer.periodic(const Duration(milliseconds: 160), (timer) async {
        if (!isAlerting) {
          timer.cancel();
          return;
        }
        strobeState = !strobeState;
        try {
          if (strobeState) {
            await TorchLight.enableTorch();
          } else {
            await TorchLight.disableTorch();
          }
        } catch (_) {}
      });
    } catch (e) {
      debugPrint('[AudioService] Torch error: $e');
    }
  }

  /// Initializes raw amplitude sampling stream
  Future<void> startAcousticListening() async {
    final hasPermission = await recorder.hasPermission();
    if (!hasPermission) {
      service.invoke('error', {'message': 'Microphone permission missing'});
      return;
    }

    // Configure stream recording to evaluate live acoustic energy
    final stream = await recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 44100,
        numChannels: 1,
        bitRate: 128000,
      ),
    );

    // Poll current amplitude every 60ms to track acoustic spike transients
    amplitudePollTimer = Timer.periodic(const Duration(milliseconds: 60), (_) async {
      if (isAlerting) return;

      try {
        final Amplitude amp = await recorder.getAmplitude();
        final currentDb = amp.current; // -160.0 to 0.0 dBFS

        // Compute adaptive ambient baseline filter (slow moving exponential average)
        if (currentDb > -80.0 && currentDb < -25.0) {
          ambientBaselineDb = (ambientBaselineDb * 0.95) + (currentDb * 0.05);
        }

        // Acoustic spike criteria:
        // 1. Current dB exceeds absolute sensitivity threshold (e.g. > -16 dBFS)
        // 2. Sudden relative jump above ambient noise floor (> 18 dB jump)
        // 3. Past the trigger cooldown period
        final double deltaAboveBaseline = currentDb - ambientBaselineDb;
        final bool isLoudEnough = currentDb >= sensitivityThresholdDb;
        final bool isSuddenSpike = deltaAboveBaseline >= 18.0;
        final bool isCooledDown = DateTime.now().difference(lastTriggerTime) > triggerCooldown;

        service.invoke('telemetry', {
          'currentDb': currentDb,
          'ambientDb': ambientBaselineDb,
          'isSpike': isLoudEnough && isSuddenSpike,
        });

        if (isLoudEnough && isSuddenSpike && isCooledDown) {
          await triggerAlert(currentDb);
        }
      } catch (_) {}
    });

    stream.listen((_) {});
  }

  // Handle client UI instructions
  service.on('stopAlert').listen((event) async {
    await stopAlert();
  });

  service.on('setSensitivity').listen((event) async {
    if (event != null && event['thresholdDb'] != null) {
      sensitivityThresholdDb = (event['thresholdDb'] as num).toDouble();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('sensitivity_threshold_db', sensitivityThresholdDb);
    }
  });

  service.on('simulateClap').listen((event) async {
    await triggerAlert(-8.5);
  });

  service.on('stopService').listen((event) async {
    amplitudePollTimer?.cancel();
    await stopAlert();
    try {
      await recorder.stop();
      await recorder.dispose();
    } catch (_) {}
    await audioPlayer.dispose();
    await service.stopSelf();
  });

  await startAcousticListening();
}