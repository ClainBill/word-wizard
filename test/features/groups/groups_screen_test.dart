import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:word_wizard/app/providers.dart';
import 'package:word_wizard/domain/groups/group_models.dart';
import 'package:word_wizard/domain/premium/premium.dart';
import 'package:word_wizard/features/groups/groups_screen.dart';
import 'package:word_wizard/services/auth_service.dart';
import 'package:word_wizard/services/groups_api.dart';
import 'package:word_wizard/services/purchases_service.dart';

class _Auth extends NoAuthService {
  final AuthUser? user;
  const _Auth(this.user);
  @override
  AuthUser? get currentUser => user;
  @override
  Stream<AuthUser?> get changes => Stream.value(user);
}

class FakeApi extends NoGroupsApi {
  final groups = <Group>[];
  final joined = <(String, String)>[];
  @override
  bool get available => true;
  @override
  Future<List<Group>> myGroups() async => groups;
  @override
  Future<String> join({required String code, required String displayName}) async {
    joined.add((code, displayName));
    if (code != 'ZDGUTUQU') throw const GroupsException('That code doesn\'t match a group.');
    return 'g-joined';
  }
}

Future<void> pump(WidgetTester tester, {required FakeApi api, AuthUser? user, bool premium = false}) async {
  final router = GoRouter(
    initialLocation: '/games/groups',
    routes: [
      GoRoute(path: '/games/groups', builder: (_, _) => const GroupsScreen()),
      GoRoute(
        path: '/games/groups/:id',
        builder: (_, s) => Scaffold(body: Text('group ${s.pathParameters['id']}')),
      ),
      GoRoute(path: '/premium', builder: (_, _) => const Scaffold(body: Text('paywall'))),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        groupsApiProvider.overrideWithValue(api),
        authServiceProvider.overrideWithValue(_Auth(user)),
        purchasesServiceProvider.overrideWithValue(FakePurchasesService(
          status: premium
              ? const PremiumStatus(access: PremiumAccess.subscription, product: PremiumProduct.annual)
              : PremiumStatus.free,
        )),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const me = AuthUser(id: 'u1', email: 'me@example.com');

  testWidgets('signed out: asked to sign in, nothing else', (tester) async {
    await pump(tester, api: FakeApi());
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Join with a code'), findsNothing);
  });

  testWidgets('free: can join, creating points at Premium', (tester) async {
    final api = FakeApi()
      ..groups.add(Group(
        id: 'g1',
        name: 'Book club',
        ownerId: 'other',
        inviteCode: 'ABCDEFGH',
        createdAt: DateTime(2026),
        memberCount: 3,
      ));
    await pump(tester, api: api, user: me);
    expect(find.text('Book club'), findsOneWidget);
    expect(find.text('3 members'), findsOneWidget);
    expect(find.text('Start a group (Premium)'), findsOneWidget);

    await tester.tap(find.text('Start a group (Premium)'));
    await tester.pumpAndSettle();
    expect(find.text('paywall'), findsOneWidget);
  });

  testWidgets('joining with a code opens the group', (tester) async {
    final api = FakeApi();
    await pump(tester, api: api, user: me, premium: true);
    expect(find.text('Start a group'), findsOneWidget);
    await tester.tap(find.text('Join with a code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Invite code'), 'zdgu tuqu');
    await tester.enterText(find.widgetWithText(TextField, 'Your name in the group'), 'Will');
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pumpAndSettle();
    expect(api.joined, [('ZDGUTUQU', 'Will')]);
    expect(find.text('group g-joined'), findsOneWidget);
  });

  testWidgets('a bad code is explained', (tester) async {
    final api = FakeApi();
    await pump(tester, api: api, user: me);
    await tester.tap(find.text('Join with a code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Invite code'), 'NOPE1234');
    await tester.enterText(find.widgetWithText(TextField, 'Your name in the group'), 'Will');
    await tester.tap(find.widgetWithText(FilledButton, 'Join'));
    await tester.pumpAndSettle();
    expect(find.text('That code doesn\'t match a group.'), findsOneWidget);
  });
}
