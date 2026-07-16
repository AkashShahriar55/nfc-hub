import 'package:flutter/material.dart';

import 'harness_home.dart';

void main() {
  runApp(const MyApp());
}

/// The example app entry point: a light+dark [MaterialApp] whose home is
/// the [HarnessHome] test harness -- auto-detecting tags via `tagStream()`,
/// showing live dual-source connection status, and offering per-family
/// reads on each detected tag. Constructed with no stream args so
/// [HarnessHome] owns the single [NfcHub] backing both its tag stream and
/// its connection-state stream (see [HarnessHome]'s doc comment).
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'nfc_hub harness',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: Scaffold(
        appBar: AppBar(title: const Text('nfc_hub harness')),
        body: const HarnessHome(),
      ),
    );
  }
}
