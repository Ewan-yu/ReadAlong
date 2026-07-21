import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader_app/core/theme/tokens.dart';
import 'package:reader_app/features/settings/settings_page.dart';
import 'package:reader_app/services/scoring/ise_credentials.dart';
import 'package:reader_app/services/scoring/score_models.dart';
import 'package:reader_app/services/scoring/xfyun_ise_provider.dart';

final class _MemoryCredentialStore implements IseCredentialStore {
  _MemoryCredentialStore([this.value]);

  IseCredentials? value;
  var clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls++;
    value = null;
  }

  @override
  Future<IseCredentials?> read() async => value;

  @override
  Future<void> write(IseCredentials credentials) async {
    value = credentials;
  }
}

final class _FakeProbe implements IseConnectionProbe {
  final tested = <IseCredentials>[];
  Object? failure;

  @override
  Future<void> testCredentials(IseCredentials credentials) async {
    tested.add(credentials);
    final error = failure;
    if (error != null) throw error;
  }
}

Future<void> _pumpSettings(
  WidgetTester tester,
  _MemoryCredentialStore store,
  _FakeProbe probe,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        iseCredentialStoreProvider.overrideWithValue(store),
        iseConnectionProbeProvider.overrideWithValue(probe),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const SettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('加载已有凭据并安全保存编辑内容', (tester) async {
    final store = _MemoryCredentialStore(
      const IseCredentials(
        appId: 'old-app',
        apiKey: 'old-key',
        apiSecret: 'old-secret',
      ),
    );
    final probe = _FakeProbe();
    await _pumpSettings(tester, store, probe);

    expect(find.text('讯飞跟读评分'), findsOneWidget);
    expect(find.text('old-app'), findsOneWidget);
    expect(find.text('old-key'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byKey(const ValueKey('settings-api-secret')),
              matching: find.byType(EditableText),
            ),
          )
          .obscureText,
      isTrue,
    );

    await tester.enterText(
      find.byKey(const ValueKey('settings-app-id')),
      ' new-app ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-api-key')),
      'new-key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-api-secret')),
      'new-secret',
    );
    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pumpAndSettle();

    expect(store.value?.appId, 'new-app');
    expect(store.value?.apiKey, 'new-key');
    expect(store.value?.apiSecret, 'new-secret');
    expect(find.text('讯飞配置已安全保存'), findsOneWidget);
  });

  testWidgets('测试连接显示成功和可理解失败', (tester) async {
    final store = _MemoryCredentialStore();
    final probe = _FakeProbe();
    await _pumpSettings(tester, store, probe);

    await tester.enterText(
      find.byKey(const ValueKey('settings-app-id')),
      'app',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-api-key')),
      'key',
    );
    await tester.enterText(
      find.byKey(const ValueKey('settings-api-secret')),
      'secret',
    );
    await tester.tap(find.byKey(const ValueKey('settings-test-connection')));
    await tester.pumpAndSettle();

    expect(probe.tested, hasLength(1));
    expect(find.text('连接成功，可以开始跟读评分'), findsOneWidget);

    probe.failure = const ScoringException('今日评分次数已用完');
    await tester.tap(find.byKey(const ValueKey('settings-test-connection')));
    await tester.pumpAndSettle();

    expect(find.text('今日评分次数已用完'), findsOneWidget);
  });

  testWidgets('空字段阻止保存和连接测试', (tester) async {
    final store = _MemoryCredentialStore();
    final probe = _FakeProbe();
    await _pumpSettings(tester, store, probe);

    await tester.tap(find.byKey(const ValueKey('settings-save')));
    await tester.pump();

    expect(find.text('请填写这一项'), findsNWidgets(3));
    expect(store.value, isNull);
    expect(probe.tested, isEmpty);
  });
}
