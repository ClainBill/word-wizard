import 'package:flutter/material.dart';

import '../../domain/games/daily_limit.dart';

/// Says today's allowance of a game is used up. A dialog rather than a
/// snackbar: the crossword keeps the keyboard up, and a snackbar would sit
/// behind it unseen.
Future<void> showDailyLimitDialog(BuildContext context, DailyPuzzleLimitReached limit) =>
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('That\'s today\'s puzzles'),
        content: Text('$limit'),
        actions: [
          FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
