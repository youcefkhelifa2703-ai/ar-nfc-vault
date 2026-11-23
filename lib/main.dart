import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

late List<CameraDescription> _cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cameras = await availableCameras();
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: ARVaultScreen(),
  ));
}

class ARVaultScreen extends StatefulWidget {
  const ARVaultScreen({super.key});

  @override
  State<ARVaultScreen> createState() => _ARVaultScreenState();
}

class _ARVaultScreenState extends State<ARVaultScreen> {
  CameraController? _cameraController;
  Position? _currentPosition;
  double _heading = 0.0;

  String? _encryptedPayload;
  double? _anchorLat;
  double? _anchorLng;
  double? _anchorHeading;
  String _statusMessage = "وجّه الكاميرا لترك كبسولة سرية في المكان";

  @override
  void initState() {
    super.initState();
    _initCamera();
    _initLocationAndCompass();
    _loadSavedAnchor();
  }

  Future<void> _initCamera() async {
    if (_cameras.isNotEmpty) {
      _cameraController = CameraController(_cameras[0], ResolutionPreset.high);
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    }
  }

  Future<void> _initLocationAndCompass() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation),
    ).listen((Position pos) {
      if (mounted) setState(() => _currentPosition = pos);
    });

    FlutterCompass.events?.listen((CompassEvent event) {
      if (mounted && event.heading != null) {
        setState(() => _heading = event.heading!);
      }
    });
  }

  Future<void> _loadSavedAnchor() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _encryptedPayload = prefs.getString('payload');
      _anchorLat = prefs.getDouble('lat');
      _anchorLng = prefs.getDouble('lng');
      _anchorHeading = prefs.getDouble('heading');
    });
  }

  enc.Key _deriveKeyFromIdentity(String identityData) {
    final bytes = utf8.encode(identityData.trim());
    final digest = sha256.convert(bytes);
    return enc.Key.fromBase64(base64Encode(digest.bytes));
  }

  Future<void> _createSpatialAnchor() async {
    if (_currentPosition == null) {
      setState(() => _statusMessage = "جاري التقاط إشارة GPS... انتظر ثوانٍ");
      return;
    }

    TextEditingController msgCtrl = TextEditingController();
    TextEditingController ninCtrl = TextEditingController();

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text("تثبيت كبسولة AR مشفرة", style: TextStyle(color: Colors.cyanAccent)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: msgCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "اكتب الرسالة السرية هنا...",
                hintStyle: TextStyle(color: Colors.grey),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ninCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "معرف الشريحة أو رقم التعريف (مفتاح الفتح)",
                hintStyle: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              if (msgCtrl.text.isEmpty || ninCtrl.text.isEmpty) return;
              final key = _deriveKeyFromIdentity(ninCtrl.text);
              final iv = enc.IV.fromLength(16);
              final encrypter = enc.Encrypter(enc.AES(key));
              final encrypted = encrypter.encrypt(msgCtrl.text, iv: iv);

              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('payload', "${iv.base64}:${encrypted.base64}");
              await prefs.setDouble('lat', _currentPosition!.latitude);
              await prefs.setDouble('lng', _currentPosition!.longitude);
              await prefs.setDouble('heading', _heading);

              await _loadSavedAnchor();
              if (mounted) {
                setState(() => _statusMessage = "تم تثبيت الكبسولة في هذه النقطة بنجاح!");
                Navigator.pop(ctx);
              }
            },
            child: const Text("قفل وتثبيت", style: TextStyle(color: Colors.cyanAccent)),
          )
        ],
      ),
    );
  }

  Future<void> _unlockWithNFC() async {
    if (_encryptedPayload == null) return;
    setState(() => _statusMessage = "قرّب بطاقة التعريف البيومترية من ظهر الهاتف...");

    bool isAvailable = await NfcManager.instance.isAvailable();
    if (!isAvailable) {
      _showManualTestUnlock();
      return;
    }

    NfcManager.instance.startSession(onDiscovered: (NfcTag tag) async {
      var idBytes = tag.data['nfca']?['identifier'] ?? tag.data['isodep']?['identifier'];
      String tagHex = idBytes != null
          ? idBytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join('').toUpperCase()
          : "TEST_ID";

      NfcManager.instance.stopSession();
      _attemptDecrypt(tagHex);
    });
  }

  void _showManualTestUnlock() {
    TextEditingController testCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text("محاكاة قراءة الشريحة", style: TextStyle(color: Colors.amber)),
        content: TextField(
          controller: testCtrl,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "أدخل المفتاح المطابق",
            hintStyle: TextStyle(color: Colors.grey),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _attemptDecrypt(testCtrl.text);
            },
            child: const Text("فك التشفير"),
          )
        ],
      ),
    );
  }

  void _attemptDecrypt(String identityKey) {
    try {
      final parts = _encryptedPayload!.split(':');
      final iv = enc.IV.fromBase64(parts[0]);
      final encryptedData = enc.Encrypted.fromBase64(parts[1]);
      final key = _deriveKeyFromIdentity(identityKey);
      final encrypter = enc.Encrypter(enc.AES(key));
      final decrypted = encrypter.decrypt(encryptedData, iv: iv);

      setState(() => _statusMessage = "🔓 تم فك التشفير: $decrypted");
    } catch (e) {
      setState(() => _statusMessage = "❌ فشل الفتح: البطاقة غير مطابقة!");
    }
  }

  bool _isAnchorInView() {
    if (_anchorLat == null || _currentPosition == null || _anchorHeading == null) return false;
    double distance = Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _anchorLat!,
      _anchorLng!,
    );
    double angleDiff = (_heading - _anchorHeading!).abs();
    if (angleDiff > 180) angleDiff = 360 - angleDiff;

    return distance <= 15.0 && angleDiff <= 25.0;
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
      );
    }

    bool visibleInAR = _isAnchorInView();

    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_cameraController!),
          if (visibleInAR)
            Center(
              child: GestureDetector(
                onTap: _unlockWithNFC,
                onLongPress: _showManualTestUnlock,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.cyanAccent, width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.cyanAccent.withOpacity(0.4), blurRadius: 20),
                    ],
                  ),
                  child: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline, color: Colors.cyanAccent, size: 50),
                      SizedBox(height: 10),
                      Text(
                        "كبسولة سرية مكتشفة هنا!",
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      SizedBox(height: 5),
                      Text(
                        "اضغط وامسح بطاقة التعريف لفتحها",
                        style: TextStyle(color: Colors.cyanAccent, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Positioned(
            top: 50,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _statusMessage,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 40,
            right: 40,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.cyanAccent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              ),
              onPressed: _createSpatialAnchor,
              icon: const Icon(Icons.add_location_alt),
              label: const Text(
                "ترك كبسولة مشفرة في هذا المكان",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
