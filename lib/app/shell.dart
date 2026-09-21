import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/premium/paywall_screen.dart';
import 'providers.dart';

/// Position of the Reader branch in the router's shell — the one tab that
/// wants to know when it's been switched to (to check the clipboard).
const readerBranchIndex = 1;

/// Position of the Games branch: the tab a free account can't open without
/// meeting the paywall first.
const gamesBranchIndex = 4;

class AppShell extends ConsumerWidget {
  final StatefulNavigationShell navigationShell;

  const AppShell({super.key, required this.navigationShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dueCount = ref.watch(dueCountProvider).valueOrNull ?? 0;

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: (i) {
          if (i == readerBranchIndex) ref.read(readerTabVisitsProvider.notifier).state++;
          navigationShell.goBranch(i, initialLocation: i == navigationShell.currentIndex);
          // Every tap on Games by a free account opens the paywall, over
          // the locked preview it lands on if dismissed (spec §3.2). This
          // is user-initiated, so no cooldown applies.
          if (i == gamesBranchIndex) {
            // Recent plays go up to the leaderboard (opted-in accounts only;
            // rate-limited inside).
            unawaited(ref.read(scoreSyncProvider).sync(userId: ref.read(authUserProvider).valueOrNull?.id));
            if (!ref.read(isPremiumProvider)) showPaywall(context, source: 'games_tab');
          }
        },
        destinations: [
          const NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          const NavigationDestination(icon: Icon(Icons.article_outlined), label: 'Reader'),
          const NavigationDestination(icon: Icon(Icons.folder_outlined), label: 'Lists'),
          NavigationDestination(
            icon: dueCount == 0
                ? const Icon(Icons.school_outlined)
                : Badge(label: Text('$dueCount'), child: const Icon(Icons.school_outlined)),
            label: 'Study',
          ),
          const NavigationDestination(icon: Icon(Icons.extension_outlined), label: 'Games'),
          const NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
        ],
      ),
    );
  }
}
