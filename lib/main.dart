import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/audio_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AudioServiceManager.initializeService();
  runApp(const ClapToFindApp());
}

class ClapToFindApp extends StatelessWidget {
  const ClapToFindApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clap to Find Phone',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF10B981), // Emerald glow
          secondary: Color(0xFF06B6D4), // Cyan
          surface: Color(0xFF131B2A),
          error: Color(0xFFEF4444),
        ),
        cardColor: const Color(0xFF131B2A),
      ),
      home: const ClapFinderHomePage(),
    );
  }
}

class ClapFinderHomePage extends StatefulWidget {
  const ClapFinderHomePage({super.key});

  @override
  State<ClapFinderHomePage> createState() => _ClapFinderHomePageState();
}

class _ClapFinderHomePageState extends State<ClapFinderHomePage>
    with SingleTickerProviderStateMixin {
  final FlutterBackgroundService _service = FlutterBackgroundService();

  bool _isServiceRunning = false;
  bool _isAlerting = false;
  double _currentDb = -60.0;
  double _ambientDb = -45.0;
  double _sensitivityThreshold = -16.0;

  bool _enableFlashlight = true;
  bool _enableVibration = true;
  bool _enableSiren = true;

  late AnimationController _pulseController;
  StreamSubscription? _telemetrySub;
  StreamSubscription? _alertSub;
  StreamSubscription? _stateSub;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _loadPreferences();
    _bindServiceListeners();
    _checkServiceStatus();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _telemetrySub?.cancel();
    _alertSub?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _sensitivityThreshold = prefs.getDouble('sensitivity_threshold_db') ?? -16.0;
      _enableFlashlight = prefs.getBool('enable_flashlight') ?? true;
      _enableVibration = prefs.getBool('enable_vibration') ?? true;
      _enableSiren = prefs.getBool('enable_siren') ?? true;
    });
  }

  Future<void> _bindServiceListeners() async {
    _telemetrySub = _service.on('telemetry').listen((data) {
      if (mounted && data != null) {
        setState(() {
          _currentDb = (data['currentDb'] as num?)?.toDouble() ?? _currentDb;
          _ambientDb = (data['ambientDb'] as num?)?.toDouble() ?? _ambientDb;
        });
      }
    });

    _alertSub = _service.on('alertTriggered').listen((data) {
      if (mounted) {
        setState(() {
          _isAlerting = true;
        });
      }
    });

    _stateSub = _service.on('alertStateChanged').listen((data) {
      if (mounted && data != null) {
        setState(() {
          _isAlerting = data['isAlerting'] ?? false;
        });
      }
    });
  }

  Future<void> _checkServiceStatus() async {
    final isRunning = await _service.isRunning();
    if (mounted) {
      setState(() {
        _isServiceRunning = isRunning;
      });
    }
  }

  Future<void> _toggleService() async {
    if (_isServiceRunning) {
      _service.invoke('stopService');
      setState(() {
        _isServiceRunning = false;
        _isAlerting = false;
        _currentDb = -60.0;
      });
    } else {
      // Check & request runtime permissions first
      final micStatus = await Permission.microphone.request();
      if (!micStatus.isGranted) {
        _showPermissionDialog('Microphone Access Required',
            'Please grant microphone permission so the app can detect clap transients.');
        return;
      }

      await Permission.notification.request();

      final started = await _service.startService();
      setState(() {
        _isServiceRunning = started;
      });
    }
  }

  void _stopAlarm() {
    _service.invoke('stopAlert');
    setState(() {
      _isAlerting = false;
    });
  }

  void _simulateClap() {
    _service.invoke('simulateClap');
    setState(() {
      _isAlerting = true;
    });
  }

  void _showPermissionDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF162032),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(message, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('Open Settings', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        title: const Text(
          'Clap to Find',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 20, letterSpacing: -0.5),
        ),
        actions: [
          IconButton(
            tooltip: 'Simulate Clap Event',
            icon: const Icon(Icons.bolt, color: Colors.amberAccent),
            onPressed: _isServiceRunning ? _simulateClap : null,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildSystemStatusBanner(),
                const Spacer(flex: 1),
                _buildMainRadarButton(),
                const SizedBox(height: 24),
                _buildAcousticMeter(),
                const Spacer(flex: 2),
                _buildControlsCard(),
                const SizedBox(height: 16),
              ],
            ),
            if (_isAlerting) _buildAlarmOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemStatusBanner() {
    final statusColor = _isServiceRunning ? const Color(0xFF10B981) : Colors.white38;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isServiceRunning ? const Color(0xFF10B981).withOpacity(0.3) : Colors.white10,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: statusColor,
              boxShadow: _isServiceRunning
                  ? [BoxShadow(color: statusColor.withOpacity(0.8), blurRadius: 10)]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _isServiceRunning ? 'Background Service Active' : 'Protection Disabled',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
          const Spacer(),
          Text(
            _isServiceRunning ? 'Listening' : 'Idle',
            style: TextStyle(fontSize: 12, color: statusColor),
          ),
        ],
      ),
    );
  }

  Widget _buildMainRadarButton() {
    return Center(
      child: GestureDetector(
        onTap: _toggleService,
        child: SizedBox(
          width: 240,
          height: 240,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_isServiceRunning) ...[
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    final progress = _pulseController.value;
                    return Container(
                      width: 170 + (progress * 70),
                      height: 170 + (progress * 70),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF10B981).withOpacity(1.0 - progress),
                          width: 2,
                        ),
                      ),
                    );
                  },
                ),
              ],
              Container(
                width: 170,
                height: 170,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: _isServiceRunning
                        ? [const Color(0xFF059669), const Color(0xFF10B981)]
                        : [const Color(0xFF1E293B), const Color(0xFF0F172A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _isServiceRunning
                          ? const Color(0xFF10B981).withOpacity(0.35)
                          : Colors.black45,
                      blurRadius: _isServiceRunning ? 30 : 10,
                      spreadRadius: _isServiceRunning ? 4 : 0,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _isServiceRunning ? Icons.mic : Icons.mic_off,
                      size: 48,
                      color: _isServiceRunning ? Colors.white : Colors.white54,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _isServiceRunning ? 'ARMED' : 'OFF',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                        color: _isServiceRunning ? Colors.white : Colors.white60,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _isServiceRunning ? 'Tap to pause' : 'Tap to arm',
                      style: TextStyle(
                        fontSize: 11,
                        color: _isServiceRunning ? Colors.white70 : Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAcousticMeter() {
    final double norm = ((_currentDb + 60.0) / 60.0).clamp(0.0, 1.0);
    final double thresholdNorm = ((_sensitivityThreshold + 60.0) / 60.0).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2A),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Live Acoustic Input',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70),
              ),
              Text(
                _isServiceRunning ? '${_currentDb.toStringAsFixed(1)} dBFS' : '-- dBFS',
                style: const TextStyle(
                  fontSize: 13,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF10B981),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _isServiceRunning ? norm : 0.05,
                  minHeight: 12,
                  backgroundColor: const Color(0xFF0F172A),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    norm >= thresholdNorm ? const Color(0xFFEF4444) : const Color(0xFF10B981),
                  ),
                ),
              ),
              Positioned(
                left: MediaQuery.of(context).size.width * 0.8 * thresholdNorm,
                top: 0,
                bottom: 0,
                child: Container(
                  width: 3,
                  color: Colors.amberAccent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControlsCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF131B2A),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Clap Sensitivity',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
              Text(
                '${_sensitivityThreshold.toStringAsFixed(0)} dB',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amberAccent),
              ),
            ],
          ),
          Slider(
            value: _sensitivityThreshold,
            min: -30.0,
            max: -10.0,
            divisions: 20,
            activeColor: const Color(0xFF10B981),
            inactiveColor: Colors.white12,
            onChanged: (val) {
              setState(() {
                _sensitivityThreshold = val;
              });
              _service.invoke('setSensitivity', {'thresholdDb': val});
            },
          ),
          const Divider(color: Colors.white10, height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildFeatureToggle(
                icon: Icons.flash_on,
                label: 'Strobe',
                active: _enableFlashlight,
                onTap: () => setState(() => _enableFlashlight = !_enableFlashlight),
              ),
              _buildFeatureToggle(
                icon: Icons.vibration,
                label: 'Vibrate',
                active: _enableVibration,
                onTap: () => setState(() => _enableVibration = !_enableVibration),
              ),
              _buildFeatureToggle(
                icon: Icons.volume_up,
                label: 'Siren',
                active: _enableSiren,
                onTap: () => setState(() => _enableSiren = !_enableSiren),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureToggle({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? const Color(0xFF10B981).withOpacity(0.2) : Colors.white10,
              border: Border.all(
                color: active ? const Color(0xFF10B981) : Colors.transparent,
              ),
            ),
            child: Icon(
              icon,
              color: active ? const Color(0xFF10B981) : Colors.white38,
              size: 22,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: active ? Colors.white : Colors.white38,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlarmOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.92),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: Colors.amberAccent,
              size: 80,
            ),
            const SizedBox(height: 16),
            const Text(
              'CLAP DETECTED!',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Device alarm, haptics, and strobe flashlight are active.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 48),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.check_circle_outline, color: Colors.black, size: 24),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: _stopAlarm,
                label: const Text(
                  'I FOUND MY PHONE (STOP)',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}