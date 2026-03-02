import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String baseUrl = "https://availability-api.onrender.com";

void main() {
  runApp(const AvailabilityApp());
}

class AvailabilityApp extends StatelessWidget {
  const AvailabilityApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Availability',
      theme: ThemeData(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

/// Israel-focused prototype normalization:
/// - keeps digits/+
/// - if starts with 0 and length 10 -> +972 + rest (drop 0)
/// - if starts with 972 -> +972...
/// - if starts with + -> keep
String normalizePhoneIL(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return "";

  // Keep + and digits
  final only = trimmed.replaceAll(RegExp(r'[^0-9+]'), '');

  if (only.startsWith('+')) {
    final d = only.replaceAll(RegExp(r'[^0-9]'), '');
    return '+$d';
  }

  final d = only.replaceAll(RegExp(r'[^0-9]'), '');
  if (d.startsWith('0') && d.length == 10) {
    return '+972${d.substring(1)}';
  }
  if (d.startsWith('972')) {
    return '+$d';
  }
  // fallback
  return '+$d';
}

String sha256Hex(String s) {
  final bytes = utf8.encode(s);
  return sha256.convert(bytes).toString();
}

/// Old dev helper (kept just in case you need it for testing)
String generateUuidLike() {
  final r = Random.secure();
  String hex(int n) => n.toRadixString(16).padLeft(2, '0');
  List<int> bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final b = bytes.map(hex).join();
  return "${b.substring(0, 8)}-${b.substring(8, 12)}-${b.substring(12, 16)}-${b.substring(16, 20)}-${b.substring(20)}";
}

class ApiClient {
  final String userIdHeader; // now this will be phone_hash
  ApiClient(this.userIdHeader);

  Map<String, String> get headers => {
        "X-User-Id": userIdHeader,
        "Content-Type": "application/json",
      };

  Future<void> setAvailable() async {
    final res = await http.post(Uri.parse("$baseUrl/presence/available"), headers: headers);
    if (res.statusCode != 200) {
      throw Exception("setAvailable failed: ${res.statusCode} ${res.body}");
    }
  }

  Future<void> setUnavailable() async {
    final res = await http.post(Uri.parse("$baseUrl/presence/unavailable"), headers: headers);
    if (res.statusCode != 200) {
      throw Exception("setUnavailable failed: ${res.statusCode} ${res.body}");
    }
  }

  Future<void> syncContactsHashed(List<String> contactHashes) async {
    final body = jsonEncode({"contact_hashes": contactHashes});
    final res = await http.post(Uri.parse("$baseUrl/contacts/sync"), headers: headers, body: body);
    if (res.statusCode != 200) {
      throw Exception("contactsSync failed: ${res.statusCode} ${res.body}");
    }
  }

  Future<List<Map<String, dynamic>>> getAvailableFriends() async {
    final res = await http.get(Uri.parse("$baseUrl/friends/available"), headers: headers);
    if (res.statusCode != 200) {
      throw Exception("friendsAvailable failed: ${res.statusCode} ${res.body}");
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final list = (data["available"] as List).cast<Map<String, dynamic>>();
    return list;
  }

  Future<Map<String, dynamic>> me() async {
    final res = await http.get(Uri.parse("$baseUrl/me"), headers: headers);
    if (res.statusCode != 200) {
      throw Exception("me failed: ${res.statusCode} ${res.body}");
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _prefsPhoneKey = "my_phone_number";
  static const _prefsUserIdHeaderKey = "my_user_id_header"; // phone hash

  late TextEditingController phoneController;

  String statusText = "Not connected yet";
  bool busy = false;

  String? userIdHeader; // phone hash
  List<Map<String, dynamic>> availableFriends = [];

  @override
  void initState() {
    super.initState();
    phoneController = TextEditingController();
    _loadPhoneAndUserId();
  }

  @override
  void dispose() {
    phoneController.dispose();
    super.dispose();
  }

  ApiClient get api => ApiClient(userIdHeader ?? "");

  Future<void> _setBusy(Future<void> Function() fn) async {
    setState(() => busy = true);
    try {
      await fn();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadPhoneAndUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPhone = prefs.getString(_prefsPhoneKey) ?? "";
    final storedHeader = prefs.getString(_prefsUserIdHeaderKey);

    phoneController.text = storedPhone;

    if (storedHeader != null && storedHeader.isNotEmpty) {
      setState(() {
        userIdHeader = storedHeader;
        statusText = "Loaded saved identity";
      });
      await _callMe();
    } else {
      setState(() {
        statusText = "Enter your phone number to connect";
      });
    }
  }

  Future<void> _savePhoneAndComputeId() async {
    final raw = phoneController.text.trim();
    final normalized = normalizePhoneIL(raw);

    if (normalized.isEmpty || normalized == "+") {
      setState(() => statusText = "Please enter a valid phone number");
      return;
    }

    final hash = sha256Hex(normalized);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsPhoneKey, raw);
    await prefs.setString(_prefsUserIdHeaderKey, hash);

    setState(() {
      userIdHeader = hash;
      statusText = "Saved phone. Your id = sha256(phone)";
    });

    await _callMe();
  }

  Future<void> _callMe() async {
    if (userIdHeader == null || userIdHeader!.isEmpty) return;
    await _setBusy(() async {
      final data = await api.me();
      setState(() => statusText = "Connected as ${data["user_id"]}");
    });
  }

  Future<void> _available() async {
    if (userIdHeader == null || userIdHeader!.isEmpty) return;
    await _setBusy(() async {
      await api.setAvailable();
      setState(() => statusText = "You are AVAILABLE");
    });
  }

  Future<void> _unavailable() async {
    if (userIdHeader == null || userIdHeader!.isEmpty) return;
    await _setBusy(() async {
      await api.setUnavailable();
      setState(() => statusText = "You are UNAVAILABLE");
    });
  }

  Future<List<String>> _collectContactHashes() async {
    // Request runtime permission (Android)
    final perm = await Permission.contacts.request();
    if (!perm.isGranted) {
      setState(() => statusText = "Contacts permission denied");
      return [];
    }

    // Fetch contacts with phone numbers
    final contacts = await FlutterContacts.getContacts(withProperties: true);

    final hashes = <String>{};
    for (final c in contacts) {
      for (final p in c.phones) {
        final normalized = normalizePhoneIL(p.number);
        if (normalized.isEmpty || normalized == "+") continue;
        hashes.add(sha256Hex(normalized));
      }
    }
    return hashes.toList();
  }

  Future<void> _syncContactsReal() async {
    if (userIdHeader == null || userIdHeader!.isEmpty) {
      setState(() => statusText = "Enter your phone number first");
      return;
    }

    await _setBusy(() async {
      setState(() => statusText = "Reading contacts...");
      final hashes = await _collectContactHashes();

      setState(() => statusText = "Syncing ${hashes.length} hashed contacts...");
      await api.syncContactsHashed(hashes);

      setState(() => statusText = "Synced ${hashes.length} contacts (hashed)");
    });
  }

  Future<void> _refreshFriends() async {
    if (userIdHeader == null || userIdHeader!.isEmpty) return;
    await _setBusy(() async {
      final list = await api.getAvailableFriends();
      setState(() {
        availableFriends = list;
        statusText = "Found ${list.length} available friend(s)";
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isReady = userIdHeader != null && userIdHeader!.isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text("Availability")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text("Server: $baseUrl", style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),

            TextField(
              controller: phoneController,
              decoration: const InputDecoration(
                labelText: "Your phone number",
                hintText: "e.g. 054-123-4567",
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.phone,
              enabled: !busy,
            ),
            const SizedBox(height: 8),

            ElevatedButton(
              onPressed: busy ? null : _savePhoneAndComputeId,
              child: const Text("Save Phone + Connect"),
            ),

            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: (!isReady || busy) ? null : _available,
                  child: const Text("I'm Available"),
                ),
                ElevatedButton(
                  onPressed: (!isReady || busy) ? null : _unavailable,
                  child: const Text("I'm Unavailable"),
                ),
                ElevatedButton(
                  onPressed: (!isReady || busy) ? null : _syncContactsReal,
                  child: const Text("Sync Contacts"),
                ),
                ElevatedButton(
                  onPressed: (!isReady || busy) ? null : _refreshFriends,
                  child: const Text("Refresh Friends"),
                ),
              ],
            ),

            const SizedBox(height: 12),
            Text(statusText, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),

            const Text("Available friends:"),
            const SizedBox(height: 8),

            Expanded(
              child: ListView.separated(
                itemCount: availableFriends.length,
                separatorBuilder: (_, __) => const Divider(),
                itemBuilder: (context, index) {
                  final f = availableFriends[index];
                  final friendId = (f["user_id"] ?? "").toString();
                  final until = (f["available_until"] ?? "").toString();
                  final name = (f["display_name"] ?? "").toString();

                  return ListTile(
                    title: Text(name.isEmpty ? friendId : "$name ($friendId)"),
                    subtitle: Text("available until: $until"),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}