import 'package:flutter_test/flutter_test.dart';

import 'package:wisemuse/services/spaced_repetition_service.dart';

void main() {
  group('intervalFor', () {
    test('掌握度 → 间隔天数映射', () {
      expect(SpacedRepetitionService.intervalFor(0), 1);
      expect(SpacedRepetitionService.intervalFor(1), 2);
      expect(SpacedRepetitionService.intervalFor(2), 4);
      expect(SpacedRepetitionService.intervalFor(3), 7);
      expect(SpacedRepetitionService.intervalFor(4), 15);
    });

    test('mastery 越界时 clamp', () {
      expect(SpacedRepetitionService.intervalFor(-1), 1);
      expect(SpacedRepetitionService.intervalFor(5), 15);
    });
  });

  group('isDue', () {
    test('从未复习 → 到期', () {
      expect(
        SpacedRepetitionService.isDue(
          mastery: 0,
          lastReviewAt: null,
          nowMicros: 0,
        ),
        isTrue,
      );
    });

    test('刚复习过 → 未到期', () {
      final now = DateTime(2026, 1, 1).microsecondsSinceEpoch;
      final reviewed = DateTime(2026, 1, 1, 12).microsecondsSinceEpoch;
      expect(
        SpacedRepetitionService.isDue(
          mastery: 1,
          lastReviewAt: reviewed,
          nowMicros: now,
        ),
        isFalse,
      );
    });

    test('超过间隔 → 到期', () {
      final reviewed = DateTime(2026, 1, 1).microsecondsSinceEpoch;
      // mastery 1 → 2 天后
      final now = DateTime(2026, 1, 4).microsecondsSinceEpoch;
      expect(
        SpacedRepetitionService.isDue(
          mastery: 1,
          lastReviewAt: reviewed,
          nowMicros: now,
        ),
        isTrue,
      );
    });

    test('mastery >= 5 → 归档不复习', () {
      expect(
        SpacedRepetitionService.isDue(
          mastery: 5,
          lastReviewAt: null,
          nowMicros: 0,
        ),
        isFalse,
      );
    });
  });
}
