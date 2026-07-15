import 'package:flutter/material.dart';
import 'package:nfc_hub/nfc_hub.dart';

import 'tag_detail_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Card Transceiver',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _ccidPlugin = NfcHub();
  CcidCard? _card;
  String? _selectedReader;
  List<String> _readers = [];
  final _capduController = TextEditingController();
  final _rapduController = TextEditingController();
  final List<String> _history = [];

  @override
  void initState() {
    super.initState();
    _refreshReaders();
  }

  Future<void> _refreshReaders() async {
    final readers = await _ccidPlugin.listReaders();
    setState(() {
      _readers = readers;
      _selectedReader = readers.isNotEmpty ? readers[0] : null;
    });
  }

  Future<void> _connectCard() async {
    if (_selectedReader != null) {
      final card = await _ccidPlugin.connect(_selectedReader!);
      setState(() {
        _card = card;
      });
    }
  }

  Future<void> _sendApdu() async {
    if (_card != null) {
      final rapdu = await _card!.transceive(_capduController.text);
      setState(() {
        _rapduController.text = rapdu ?? '';
        _history.insert(0, 'C-APDU: ${_capduController.text}, R-APDU: $rapdu');
      });
    }
  }

  Future<void> _readTagDetails() async {
    if (_card == null) return;
    try {
      final driver = await identifyTag(_card!);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => TagDetailPage(driver: driver),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // Detection failures include the ATR and every probe's outcome in
      // their message (see identifyTag()'s doc comment), so a long
      // duration here is deliberate: it gives time to read or screenshot
      // the diagnostic without needing a connected debugger/console.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not identify tag: $e'),
          duration: const Duration(seconds: 30),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart Card Transceiver'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                DropdownButton<String>(
                  value: _selectedReader,
                  items: _readers.map((String value) {
                    return DropdownMenuItem<String>(
                      value: value,
                      child: Text(value),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedReader = value;
                    });
                  },
                ),
              ],
            ),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _refreshReaders,
                  child: const Text('Refresh'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _connectCard,
                  child: const Text('Connect'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _readTagDetails,
                  child: const Text('Read Tag Details'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _capduController,
              decoration: const InputDecoration(
                labelText: 'C-APDU (hex)',
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _sendApdu,
              child: const Text('Send APDU'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _rapduController,
              decoration: const InputDecoration(
                labelText: 'R-APDU',
              ),
              readOnly: true,
            ),
            const SizedBox(height: 16),
            const Text('History:'),
            Expanded(
              child: ListView.builder(
                itemCount: _history.length,
                itemBuilder: (context, index) {
                  return Text(_history[index]);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
