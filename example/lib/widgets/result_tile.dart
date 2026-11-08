import 'package:flutter/material.dart';

/// A labelled result row for the harness: a title plus either a spinner
/// (loading), a selectable error, or a selectable monospace value. Used for
/// every read so a failure is always visible and copyable.
class ResultTile extends StatelessWidget {
  const ResultTile({
    super.key,
    required this.title,
    this.value,
    this.error,
    this.loading = false,
  });

  final String title;
  final String? value;
  final Object? error;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body;
    if (loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    } else if (error != null) {
      body = SelectableText(
        'Failed: $error',
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.error),
      );
    } else {
      body = SelectableText(
        value ?? '(none)',
        style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
  }
}
