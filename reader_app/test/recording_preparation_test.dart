import 'package:flutter_test/flutter_test.dart';
import 'package:reader_app/services/recording/recording_preparation.dart';

void main() {
  test('先稳定麦克风，再给出三拍倒计时并返回内容零点偏移', () async {
    final updates = <RecordingPreparationUpdate>[];
    const protocol = TimedRecordingPreparationProtocol(
      stabilization: Duration(milliseconds: 1),
      beatDuration: Duration(milliseconds: 1),
    );

    final offset = await protocol.run(
      isActive: () => true,
      onUpdate: updates.add,
    );

    expect(updates.first.stage, RecordingPreparationStage.stabilizing);
    expect(
      updates.skip(1).map((value) => value.countdown),
      [3, 2, 1],
    );
    expect(offset, greaterThan(Duration.zero));
  });

  test('页面离开后准备协议立即终止', () async {
    var active = true;
    const protocol = TimedRecordingPreparationProtocol(
      stabilization: Duration(milliseconds: 1),
      beatDuration: Duration(milliseconds: 1),
    );

    await expectLater(
      protocol.run(
        isActive: () => active,
        onUpdate: (update) {
          if (update.stage == RecordingPreparationStage.stabilizing) {
            active = false;
          }
        },
      ),
      throwsA(isA<RecordingPreparationCancelled>()),
    );
  });
}
