import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/appdb/app_database_providers.dart';
import '../../data/appdb/shelf_index.dart';
import '../dubbing/dubbing_repository.dart';

enum ManagedRecordingKind { take, mix }

final class ManagedRecordingItem {
  const ManagedRecordingItem.take({
    required this.take,
    required this.project,
  })  : mix = null,
        kind = ManagedRecordingKind.take;

  const ManagedRecordingItem.mix({
    required this.mix,
    required this.project,
  })  : take = null,
        kind = ManagedRecordingKind.mix;

  final ManagedRecordingKind kind;
  final DubbingTake? take;
  final DubbingMix? mix;
  final DubbingProject project;

  String get id => take?.id ?? mix!.id;
  String get selectionKey => '${kind.name}:$id';
  Duration get duration => take?.duration ?? mix!.duration;
  DateTime get createdAt => take?.createdAt ?? mix!.createdAt;
}

final class ManagedRecordingProject {
  const ManagedRecordingProject({
    required this.book,
    required this.project,
    required this.items,
  });

  final ShelfBook book;
  final DubbingProject project;
  final List<ManagedRecordingItem> items;

  int get takeCount =>
      items.where((item) => item.kind == ManagedRecordingKind.take).length;
  int get mixCount =>
      items.where((item) => item.kind == ManagedRecordingKind.mix).length;
}

final class RecordingManagementState {
  const RecordingManagementState({
    required this.projects,
    this.selectedKeys = const <String>{},
    this.deleting = false,
    this.message,
    this.messageIsError = false,
  });

  final List<ManagedRecordingProject> projects;
  final Set<String> selectedKeys;
  final bool deleting;
  final String? message;
  final bool messageIsError;

  Iterable<ManagedRecordingItem> get items =>
      projects.expand((project) => project.items);
  int get itemCount => items.length;
  int get takeCount =>
      items.where((item) => item.kind == ManagedRecordingKind.take).length;
  int get mixCount => itemCount - takeCount;

  RecordingManagementState copyWith({
    List<ManagedRecordingProject>? projects,
    Set<String>? selectedKeys,
    bool? deleting,
    Object? message = _managementUnset,
    bool? messageIsError,
  }) =>
      RecordingManagementState(
        projects: projects ?? this.projects,
        selectedKeys: selectedKeys ?? this.selectedKeys,
        deleting: deleting ?? this.deleting,
        message: identical(message, _managementUnset)
            ? this.message
            : message as String?,
        messageIsError: messageIsError ?? this.messageIsError,
      );
}

const _managementUnset = Object();

final recordingManagementControllerProvider = AutoDisposeAsyncNotifierProvider<
    RecordingManagementController,
    RecordingManagementState>(RecordingManagementController.new);

class RecordingManagementController
    extends AutoDisposeAsyncNotifier<RecordingManagementState> {
  late final DubbingRepository _repository;
  late final ShelfIndex _shelfIndex;
  var _deleting = false;

  @override
  Future<RecordingManagementState> build() async {
    _repository = await ref.watch(dubbingRepositoryProvider.future);
    _shelfIndex = await ref.watch(shelfIndexProvider.future);
    return _load();
  }

  Future<RecordingManagementState> _load({
    Set<String> selectedKeys = const <String>{},
    String? message,
    bool messageIsError = false,
  }) async {
    final books = await _shelfIndex.listBooks();
    final projects = <ManagedRecordingProject>[];
    var failedScopes = 0;
    for (final book in books) {
      List<DubbingProject> bookProjects;
      try {
        bookProjects = await _repository.listProjects(book.libraryId);
      } on Object {
        failedScopes++;
        continue;
      }
      for (final project in bookProjects) {
        List<DubbingTake> takes;
        List<DubbingMix> mixes;
        try {
          takes = await _repository.listTakes(project.id);
          mixes = await _repository.listMixes(project.id);
        } on Object {
          failedScopes++;
          continue;
        }
        final items = <ManagedRecordingItem>[
          for (final take in takes)
            ManagedRecordingItem.take(take: take, project: project),
          for (final mix in mixes)
            ManagedRecordingItem.mix(mix: mix, project: project),
        ]..sort((left, right) => right.createdAt.compareTo(left.createdAt));
        if (items.isEmpty) continue;
        projects.add(ManagedRecordingProject(
          book: book,
          project: project,
          items: List.unmodifiable(items),
        ));
      }
    }
    if (projects.isEmpty && failedScopes > 0) {
      throw StateError('录音目录暂时无法读取');
    }
    projects.sort((left, right) {
      final bookOrder = right.book.importedAt.compareTo(left.book.importedAt);
      if (bookOrder != 0) return bookOrder;
      return right.project.updatedAt.compareTo(left.project.updatedAt);
    });
    final validKeys = {
      for (final project in projects)
        for (final item in project.items) item.selectionKey,
    };
    return RecordingManagementState(
      projects: List.unmodifiable(projects),
      selectedKeys: Set.unmodifiable(selectedKeys.intersection(validKeys)),
      message: message ?? (failedScopes > 0 ? '部分录音暂时无法读取，其他项目仍可管理' : null),
      messageIsError: messageIsError || failedScopes > 0,
    );
  }

  void toggle(String key) {
    final current = state.valueOrNull;
    if (current == null || current.deleting) return;
    final selected = {...current.selectedKeys};
    selected.contains(key) ? selected.remove(key) : selected.add(key);
    state = AsyncData(current.copyWith(
      selectedKeys: Set.unmodifiable(selected),
      message: null,
    ));
  }

  void toggleProject(ManagedRecordingProject project) {
    final current = state.valueOrNull;
    if (current == null || current.deleting) return;
    final keys = project.items.map((item) => item.selectionKey).toSet();
    final selected = {...current.selectedKeys};
    if (selected.containsAll(keys)) {
      selected.removeAll(keys);
    } else {
      selected.addAll(keys);
    }
    state = AsyncData(current.copyWith(
      selectedKeys: Set.unmodifiable(selected),
      message: null,
    ));
  }

  void toggleAll() {
    final current = state.valueOrNull;
    if (current == null || current.deleting) return;
    final all = current.items.map((item) => item.selectionKey).toSet();
    state = AsyncData(current.copyWith(
      selectedKeys: current.selectedKeys.length == all.length
          ? const <String>{}
          : Set.unmodifiable(all),
      message: null,
    ));
  }

  Future<void> deleteSelected() async {
    final current = state.valueOrNull;
    if (current == null ||
        current.selectedKeys.isEmpty ||
        current.deleting ||
        _deleting) {
      return;
    }
    _deleting = true;
    final selectedItems = current.items
        .where((item) => current.selectedKeys.contains(item.selectionKey))
        .toList(growable: false);
    state = AsyncData(current.copyWith(deleting: true, message: null));
    final failed = <String>{};
    final projectsWithDeletedMixes = <String, DubbingProject>{};
    var deleted = 0;
    try {
      for (final item in selectedItems) {
        try {
          if (item.kind == ManagedRecordingKind.take) {
            await _repository.deleteTake(item.id);
          } else {
            await _repository.deleteMix(item.id);
            projectsWithDeletedMixes[item.project.id] = item.project;
          }
          deleted++;
        } on Object {
          failed.add(item.selectionKey);
        }
      }
      for (final entry in projectsWithDeletedMixes.entries) {
        try {
          final remaining = await _repository.listMixes(entry.key);
          if (remaining.isEmpty &&
              entry.value.status == DubbingProjectStatus.complete) {
            await _repository.updateProjectStatus(
              entry.key,
              DubbingProjectStatus.draft,
            );
          }
        } on Object {
          // Asset deletion already succeeded. The next dubbing controller load
          // derives usable actions from actual Takes and Mixes.
        }
      }
      final message = failed.isEmpty
          ? '已删除 $deleted 项录音或作品'
          : '已删除 $deleted 项，另有 ${failed.length} 项未删除，可以重试';
      try {
        state = AsyncData(await _load(
          selectedKeys: failed,
          message: message,
          messageIsError: failed.isNotEmpty,
        ));
      } on Object {
        state = AsyncData(current.copyWith(
          deleting: false,
          selectedKeys: Set.unmodifiable(failed),
          message: '删除操作已执行，但列表没有刷新成功；重新进入页面即可更新',
          messageIsError: true,
        ));
      }
    } finally {
      _deleting = false;
      final latest = state.valueOrNull;
      if (latest != null && latest.deleting) {
        state = AsyncData(latest.copyWith(deleting: false));
      }
    }
  }

  void clearMessage() {
    final current = state.valueOrNull;
    if (current != null && current.message != null) {
      state = AsyncData(current.copyWith(message: null));
    }
  }
}
