import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Terms of use or the privacy policy, bundled with the app so they're
/// reachable from the paywall offline (spec §3.1). The same text is what
/// the store listing links to once there's a website.
class LegalScreen extends StatelessWidget {
  final String title;
  final String asset;

  const LegalScreen.terms({super.key}) : title = 'Terms of use', asset = 'docs/TERMS.md';

  const LegalScreen.privacy({super.key})
    : title = 'Privacy policy',
      asset = 'docs/PRIVACY_POLICY.md';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(asset),
        builder: (context, snapshot) {
          final text = snapshot.data;
          if (text == null) return const Center(child: CircularProgressIndicator());
          return Markdown(data: text, padding: const EdgeInsets.fromLTRB(20, 8, 20, 32));
        },
      ),
    );
  }
}
