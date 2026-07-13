import 'package:flutter/material.dart';

import 'point_reading_models.dart';

Rect containedImageRect({
  required Size canvasSize,
  required Size imageSize,
}) {
  if (!_validSize(canvasSize) || !_validSize(imageSize)) return Rect.zero;
  final fitted = applyBoxFit(BoxFit.contain, imageSize, canvasSize);
  return Alignment.center
      .inscribe(fitted.destination, Offset.zero & canvasSize);
}

Offset? viewportPointToNormalized({
  required Offset viewportPoint,
  required TransformationController transformation,
  required Rect imageRect,
}) {
  if (imageRect.isEmpty) return null;
  final scenePoint = transformation.toScene(viewportPoint);
  if (scenePoint.dx < imageRect.left ||
      scenePoint.dx > imageRect.right ||
      scenePoint.dy < imageRect.top ||
      scenePoint.dy > imageRect.bottom) {
    return null;
  }
  return Offset(
    (scenePoint.dx - imageRect.left) / imageRect.width,
    (scenePoint.dy - imageRect.top) / imageRect.height,
  );
}

List<ReaderSentence> hitTestSentences({
  required Iterable<ReaderSentence> sentences,
  required Offset normalizedPoint,
}) {
  final all = List<ReaderSentence>.of(sentences);
  final candidates = all.where((sentence) {
    final tolerance = (sentence.bbox.height * 0.15).clamp(0.0, 0.01);
    return sentence.bbox.expand(tolerance).contains(normalizedPoint);
  }).toList()
    ..sort((left, right) {
      final areaOrder = left.bbox.area.compareTo(right.bbox.area);
      return areaOrder != 0
          ? areaOrder
          : left.sequence.compareTo(right.sequence);
    });
  if (candidates.isEmpty) return const [];

  final winner = candidates.first;
  if (!winner.sharedBbox) return [winner];
  final group = all
      .where(
        (sentence) =>
            sentence.pageNumber == winner.pageNumber &&
            sentence.sharedBbox &&
            sentence.bbox == winner.bbox,
      )
      .toList()
    ..sort((left, right) => left.sequence.compareTo(right.sequence));
  return List.unmodifiable(group);
}

bool _validSize(Size size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.width > 0 &&
    size.height > 0;
