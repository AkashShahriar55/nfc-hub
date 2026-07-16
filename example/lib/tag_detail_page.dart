import 'package:flutter/material.dart';

import 'tag_readout.dart';
import 'widgets/result_tile.dart';

/// Displays a tag's cached [TagReadout] — the TagInfo summary plus every
/// family-specific read, all captured at detection time (while the tag was
/// present). Pure display: it makes NO live card access, so it works after
/// the card has been removed from the reader / lifted off the phone. That's
/// the whole point — reads happen at tap time, not when you open this page.
class TagDetailPage extends StatelessWidget {
  final TagReadout readout;

  const TagDetailPage({super.key, required this.readout});

  @override
  Widget build(BuildContext context) {
    final info = readout.info;
    final tagInfoValue = info != null ? tagInfoLines(info).join('\n') : null;
    return Scaffold(
      appBar: AppBar(title: Text('Tag Detail (${readout.driver.runtimeType})')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ResultTile(
              title: 'Tag Info',
              value: tagInfoValue,
              error: readout.infoError,
            ),
            const Divider(height: 32),
            for (final r in readout.results)
              ResultTile(title: r.title, value: r.value, error: r.error),
          ],
        ),
      ),
    );
  }
}
