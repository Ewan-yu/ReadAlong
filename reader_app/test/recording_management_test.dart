import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:reader_app/core/theme/tokens.dart';
import 'package:reader_app/data/appdb/app_database_providers.dart';
import 'package:reader_app/data/appdb/shelf_index.dart';
import 'package:reader_app/features/dubbing/dubbing_file_store.dart';
import 'package:reader_app/features/dubbing/dubbing_repository.dart';
import 'package:reader_app/features/settings/recording_management_controller.dart';
import 'package:reader_app/features/settings/recording_management_page.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('按绘本汇总录音并批量删除真实数据库行和私有文件', () async {
    final temporary = await Directory.systemTemp.createTemp('recording_admin_');
    final index = ShelfIndex(
      databasePath: p.join(temporary.path, 'app.db'),
      databaseFactory: databaseFactoryFfi,
    );
    final repository = LocalDubbingRepository(
      shelfIndex: index,
      fileStore: DubbingFileStore(documentsDirectory: temporary),
      idGenerator: _Ids().next,
    );
    await index.add(_book());
    final sentenceProject = await repository.createProject(_draft(
      DubbingMode.sentence,
    ));
    final fullProject = await repository.createProject(_draft(
      DubbingMode.full,
    ));
    final source = File(p.join(temporary.path, 'source.wav'));
    await source.writeAsBytes(List<int>.filled(64, 1));
    final sentenceOne = await repository.saveTake(
      projectId: sentenceProject.id,
      kind: DubbingTakeKind.sentence,
      sourceAudio: source,
      duration: const Duration(seconds: 2),
      sentenceId: 's1',
    );
    final sentenceTwo = await repository.saveTake(
      projectId: sentenceProject.id,
      kind: DubbingTakeKind.sentence,
      sourceAudio: source,
      duration: const Duration(seconds: 3),
      sentenceId: 's2',
    );
    await repository.selectTake(sentenceOne.id);
    final fullTake = await repository.saveTake(
      projectId: fullProject.id,
      kind: DubbingTakeKind.full,
      sourceAudio: source,
      duration: const Duration(seconds: 8),
    );
    final mixOutput = await repository.prepareMixOutput(sentenceProject.id);
    await File(mixOutput.absolutePath).parent.create(recursive: true);
    await File(mixOutput.absolutePath).writeAsBytes([1, 2, 3]);
    final mix = await repository.saveMix(
      output: mixOutput,
      variant: DubbingMixVariant.background,
      sourceTakeFingerprint: 'fingerprint',
      duration: const Duration(seconds: 8),
    );
    await repository.updateProjectStatus(
      sentenceProject.id,
      DubbingProjectStatus.complete,
    );

    final container = ProviderContainer(overrides: [
      shelfIndexProvider.overrideWith((_) async => index),
      dubbingRepositoryProvider.overrideWith((_) async => repository),
    ]);
    final lease = container.listen(
      recordingManagementControllerProvider,
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(() async {
      lease.close();
      container.dispose();
      await pumpEventQueue();
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });

    final initial =
        await container.read(recordingManagementControllerProvider.future);
    expect(initial.projects, hasLength(2));
    expect(initial.takeCount, 3);
    expect(initial.mixCount, 1);

    final sentenceGroup = initial.projects.singleWhere(
      (group) => group.project.id == sentenceProject.id,
    );
    container
        .read(recordingManagementControllerProvider.notifier)
        .toggleProject(sentenceGroup);
    expect(
      container
          .read(recordingManagementControllerProvider)
          .requireValue
          .selectedKeys,
      hasLength(3),
    );

    await container
        .read(recordingManagementControllerProvider.notifier)
        .deleteSelected();

    final remaining =
        container.read(recordingManagementControllerProvider).requireValue;
    expect(remaining.takeCount, 1);
    expect(remaining.mixCount, 0);
    expect(remaining.projects.single.project.id, fullProject.id);
    expect(await repository.listTakes(sentenceProject.id), isEmpty);
    expect(await repository.listMixes(sentenceProject.id), isEmpty);
    expect(
      (await repository.findProject(sentenceProject.id))?.status,
      DubbingProjectStatus.draft,
    );
    expect(
        File(repository.resolveAudioPath(sentenceOne)).existsSync(), isFalse);
    expect(
        File(repository.resolveAudioPath(sentenceTwo)).existsSync(), isFalse);
    expect(File(repository.resolveMixAudioPath(mix)).existsSync(), isFalse);
    expect(File(repository.resolveAudioPath(fullTake)).existsSync(), isTrue);
  });

  testWidgets('管理页小屏可全选并经过确认后批量删除', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = _WidgetManagementController(_widgetState());

    await tester.pumpWidget(ProviderScope(
      overrides: [
        recordingManagementControllerProvider.overrideWith(() => controller),
      ],
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const RecordingManagementPage(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('2 条录音 · 1 个作品'), findsWidgets);
    expect(find.byKey(const ValueKey('recording-management-list')),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester
        .tap(find.byKey(const ValueKey('recording-management-select-all')));
    await tester.pump();
    expect(find.text('已选择 3 项'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('recording-management-delete')));
    await tester.pumpAndSettle();
    expect(find.text('删除选中的 3 项？'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('recording-management-confirm-delete')),
    );
    await tester.pumpAndSettle();

    expect(controller.deleteCalls, 1);
    expect(find.text('还没有保存的录音'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final class _Ids {
  var value = 0;
  String next() => 'id-${++value}';
}

ShelfBook _book() => ShelfBook(
      libraryId: 'book-copy',
      sourceBookId: 'source-book',
      title: 'Long and Short',
      pageCount: 10,
      bookDir: 'book',
      thumbnailPath: 'thumb.jpg',
      packageSha256: 'a' * 64,
      importedAt: DateTime.utc(2026, 7, 26),
    );

DubbingProjectDraft _draft(DubbingMode mode) => DubbingProjectDraft(
      libraryId: 'book-copy',
      sourceBookId: 'source-book',
      resourceSha256: 'a' * 64,
      timelineSha256: 'b' * 64,
      mode: mode,
    );

RecordingManagementState _widgetState() {
  final book = _book();
  final project = DubbingProject(
    id: 'project',
    libraryId: book.libraryId,
    sourceBookId: book.sourceBookId,
    resourceSha256: 'a' * 64,
    timelineSha256: 'b' * 64,
    mode: DubbingMode.sentence,
    status: DubbingProjectStatus.complete,
    createdAt: DateTime.utc(2026, 7, 26),
    updatedAt: DateTime.utc(2026, 7, 26),
  );
  final takes = [
    for (var index = 1; index <= 2; index++)
      DubbingTake(
        id: 'take-$index',
        projectId: project.id,
        sentenceId: 's$index',
        takeKind: DubbingTakeKind.sentence,
        audioRelativePath: 'take-$index.wav',
        duration: Duration(seconds: index + 1),
        isSelected: index == 1,
        scoreStatus: DubbingTakeScoreStatus.scored,
        createdAt: DateTime.utc(2026, 7, 26, 12, index),
      ),
  ];
  final mix = DubbingMix(
    id: 'mix-1',
    projectId: project.id,
    audioRelativePath: 'mix.m4a',
    variant: DubbingMixVariant.background,
    sourceTakeFingerprint: 'fingerprint',
    duration: const Duration(seconds: 8),
    createdAt: DateTime.utc(2026, 7, 26, 13),
  );
  return RecordingManagementState(projects: [
    ManagedRecordingProject(
      book: book,
      project: project,
      items: [
        for (final take in takes)
          ManagedRecordingItem.take(take: take, project: project),
        ManagedRecordingItem.mix(mix: mix, project: project),
      ],
    ),
  ]);
}

final class _WidgetManagementController extends RecordingManagementController {
  _WidgetManagementController(this.initial);

  final RecordingManagementState initial;
  var deleteCalls = 0;

  @override
  Future<RecordingManagementState> build() async => initial;

  @override
  Future<void> deleteSelected() async {
    deleteCalls++;
    state = const AsyncData(RecordingManagementState(projects: []));
  }
}
