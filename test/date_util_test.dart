import 'package:daymark/core/util/date_util.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dateKey / isoDay', () {
    test('自然日格式化', () {
      final d = DateTime(2026, 8, 11, 22, 30);
      expect(dateKey(d), '2026-08-11');
      expect(isoDay(d), '2026-08-11T00:00:00+08:00');
      expect(isoNextDay(d), '2026-08-12T00:00:00+08:00');
    });

    test('跨月/跨年', () {
      expect(isoNextDay(DateTime(2026, 12, 31)), '2027-01-01T00:00:00+08:00');
      expect(monthKey(DateTime(2026, 1, 15)), '2026-01');
    });
  });

  group('isoWeekNumber', () {
    test('ISO 周数', () {
      // 2026-08-11 是周二
      expect(isoWeekNumber(DateTime(2026, 8, 11)), 33);
      expect(weekKey(DateTime(2026, 8, 11)), '2026-W33');
    });
  });

  group('hhmm / parseHhmm', () {
    test('格式化', () {
      expect(hhmm(DateTime(2026, 8, 11, 9, 5)), '09:05');
    });

    test('解析合法', () {
      final now = DateTime(2026, 8, 11);
      final t = parseHhmm('9:05', now);
      expect(t, DateTime(2026, 8, 11, 9, 5));
    });

    test('解析非法', () {
      final now = DateTime(2026, 8, 11);
      expect(parseHhmm('25:00', now), isNull);
      expect(parseHhmm('ab:cd', now), isNull);
      expect(parseHhmm('', now), isNull);
    });
  });
}
