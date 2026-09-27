import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'providers/breath_provider.dart';
import 'screens/device_scan_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  _hideNavigationBar();
  runApp(const MyApp());
}

/// Hides the bottom navigation bar (back / home / recents).
/// The status bar (clock, battery) is kept visible.
void _hideNavigationBar() {
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Android resets system UI when the app goes to background.
  /// Re-apply immersive mode on every resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _hideNavigationBar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => BreathProvider(),
      child: MaterialApp(
        title: 'Monitor Oddechu',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          primarySwatch: Colors.blue,
          scaffoldBackgroundColor: Colors.grey[100],
          useMaterial3: true,
        ),
        home: const SplashScreen(),
      ),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    bool allGranted = statuses.values.every((status) => status.isGranted);

    if (mounted) {
      if (allGranted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => const DeviceScanScreen(),
          ),
        );
      } else {
        _showPermissionDialog();
      }
    }
  }

  void _showPermissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Wymagane uprawnienia'),
        content: const Text(
          'Aplikacja wymaga uprawnień Bluetooth i lokalizacji do działania. '
          'Przejdź do ustawień i nadaj wymagane uprawnienia.',
        ),
        actions: [
          TextButton(
            onPressed: () => openAppSettings(),
            child: const Text('Otwórz ustawienia'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _checkPermissions();
            },
            child: const Text('Spróbuj ponownie'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.air, size: 100, color: Theme.of(context).primaryColor),
            const SizedBox(height: 24),
            const Text(
              'Monitor Oddechu',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('Sprawdzanie uprawnień...'),
          ],
        ),
      ),
    );
  }
}
