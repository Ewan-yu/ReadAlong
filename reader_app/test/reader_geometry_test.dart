import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:reader_app/features/reader/point_reading_models.dart';
import 'package:reader_app/features/reader/reader_geometry.dart';

ReaderSentence _sentence({
  required String id,
  required int sequence,
  required NormalizedRect bbox,
  bool shared = false,
}) =>
    ReaderSentence(
      id: id,
      pageNumber: 1,
      sequence: sequence,
      text: id,
      bbox: bbox,
      sharedBbox: shared,
      audio: SentenceAudioClip(
        path: '$id.ogg',
        start: Duration.zero,
        end: const Duration(seconds: 1),
      ),
    );

void main() {
  group('containedImageRect', () {
    test('竖图在宽画布内产生左右留白', () {
      final rect = containedImageRect(
        canvasSize: const Size(1200, 800),
        imageSize: const Size(600, 800),
      );

      expect(rect, const Rect.fromLTWH(300, 0, 600, 800));
    });

    test('横图在高画布内产生上下留白', () {
      final rect = containedImageRect(
        canvasSize: const Size(800, 1200),
        imageSize: const Size(800, 600),
      );

      expect(rect, const Rect.fromLTWH(0, 300, 800, 600));
    });

    test('相同比例填满画布且非法尺寸返回 Rect.zero', () {
      expect(
        containedImageRect(
          canvasSize: const Size(600, 800),
          imageSize: const Size(1200, 1600),
        ),
        const Rect.fromLTWH(0, 0, 600, 800),
      );
      expect(
        containedImageRect(
          canvasSize: Size.zero,
          imageSize: const Size(1200, 1600),
        ),
        Rect.zero,
      );
    });
  });

  group('viewportPointToNormalized', () {
    test('图片边界可归一化且 letterbox 点击返回空', () {
      final transformation = TransformationController();
      addTearDown(transformation.dispose);
      const imageRect = Rect.fromLTWH(300, 0, 600, 800);

      expect(
        viewportPointToNormalized(
          viewportPoint: imageRect.topLeft,
          transformation: transformation,
          imageRect: imageRect,
        ),
        Offset.zero,
      );
      expect(
        viewportPointToNormalized(
          viewportPoint: imageRect.bottomRight,
          transformation: transformation,
          imageRect: imageRect,
        ),
        const Offset(1, 1),
      );
      expect(
        viewportPointToNormalized(
          viewportPoint: const Offset(299, 400),
          transformation: transformation,
          imageRect: imageRect,
        ),
        isNull,
      );
    });

    test('缩放和平移后的视觉点反算为相同归一化坐标', () {
      const imageRect = Rect.fromLTWH(100, 50, 400, 600);
      const normalized = Offset(0.25, 0.75);
      final scenePoint = Offset(
        imageRect.left + imageRect.width * normalized.dx,
        imageRect.top + imageRect.height * normalized.dy,
      );

      for (final matrix in [
        Matrix4.identity(),
        Matrix4.identity()..scale(2.0),
        Matrix4.identity()
          ..translate(-80.0, -120.0)
          ..scale(2.0),
      ]) {
        final transformation = TransformationController(matrix);
        final viewportPoint = MatrixUtils.transformPoint(matrix, scenePoint);

        final result = viewportPointToNormalized(
          viewportPoint: viewportPoint,
          transformation: transformation,
          imageRect: imageRect,
        );
        expect(result, isNotNull);
        expect(result!.dx, closeTo(normalized.dx, 0.000001));
        expect(result.dy, closeTo(normalized.dy, 0.000001));
        transformation.dispose();
      }
    });
  });

  group('hitTestSentences', () {
    test('按公式扩展容差并裁剪页面边界', () {
      final edge = _sentence(
        id: 'edge',
        sequence: 1,
        bbox: const NormalizedRect(
          x: 0,
          y: 0,
          width: 0.2,
          height: 0.02,
        ),
      );

      expect(
        hitTestSentences(
          sentences: [edge],
          normalizedPoint: const Offset(0.201, 0.01),
        ),
        [edge],
      );
      expect(
        hitTestSentences(
          sentences: [edge],
          normalizedPoint: const Offset(0.204, 0.01),
        ),
        isEmpty,
      );
    });

    test('重叠时原始面积更小者优先', () {
      final large = _sentence(
        id: 'large',
        sequence: 1,
        bbox: const NormalizedRect(
          x: 0.1,
          y: 0.1,
          width: 0.6,
          height: 0.4,
        ),
      );
      final small = _sentence(
        id: 'small',
        sequence: 2,
        bbox: const NormalizedRect(
          x: 0.2,
          y: 0.2,
          width: 0.2,
          height: 0.1,
        ),
      );

      expect(
        hitTestSentences(
          sentences: [large, small],
          normalizedPoint: const Offset(0.3, 0.25),
        ),
        [small],
      );
    });

    test('面积相同按 seq 优先', () {
      const bbox = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1);
      final later = _sentence(id: 'later', sequence: 3, bbox: bbox);
      final earlier = _sentence(id: 'earlier', sequence: 2, bbox: bbox);

      expect(
        hitTestSentences(
          sentences: [later, earlier],
          normalizedPoint: const Offset(0.2, 0.15),
        ),
        [earlier],
      );
    });

    test('共享 bbox 返回精确同框的完整有序组', () {
      const bbox = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1);
      final third =
          _sentence(id: 'third', sequence: 3, bbox: bbox, shared: true);
      final first =
          _sentence(id: 'first', sequence: 1, bbox: bbox, shared: true);
      final otherBox = _sentence(
        id: 'other',
        sequence: 2,
        bbox: const NormalizedRect(
          x: 0.1,
          y: 0.1,
          width: 0.300001,
          height: 0.1,
        ),
        shared: true,
      );

      expect(
        hitTestSentences(
          sentences: [third, otherBox, first],
          normalizedPoint: const Offset(0.2, 0.15),
        ).map((item) => item.id),
        ['first', 'third'],
      );
    });

    test('普通同框句不并组且未命中返回空', () {
      const bbox = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1);
      final first = _sentence(id: 'first', sequence: 1, bbox: bbox);
      final second = _sentence(id: 'second', sequence: 2, bbox: bbox);

      expect(
        hitTestSentences(
          sentences: [second, first],
          normalizedPoint: const Offset(0.2, 0.15),
        ),
        [first],
      );
      expect(
        hitTestSentences(
          sentences: [first],
          normalizedPoint: const Offset(0.9, 0.9),
        ),
        isEmpty,
      );
    });
  });
}
