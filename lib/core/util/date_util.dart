/// 日期工具：统一 +08:00 自然日语义（沿用 daily-work-report 惯例）。
library;

/// 按本地时区把 [date] 归入自然日，返回当天 00:00。
DateTime dayStart(DateTime date) => DateTime(date.year, date.month, date.day);

/// 自然日文件名：`2026-08-11`
String dateKey(DateTime date) {
  final d = date;
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// ISO 8601 自然日：`2026-08-11T00:00:00+08:00`
String isoDay(DateTime date) {
  final d = dayStart(date);
  return '${dateKey(d)}T00:00:00+08:00';
}

/// ISO 8601 次日 00:00：`2026-08-12T00:00:00+08:00`
String isoNextDay(DateTime date) {
  final d = dayStart(date).add(const Duration(days: 1));
  return '${dateKey(d)}T00:00:00+08:00';
}

/// 周数（ISO 8601），用于周报文件名 `2026-W33`
int isoWeekNumber(DateTime date) {
  // ISO 周数：周四所在周为第几周
  final thursday = date.add(Duration(days: 4 - date.weekday));
  final firstOfYear = DateTime(thursday.year, 1, 1);
  final week = ((thursday.difference(firstOfYear).inDays) / 7).floor() + 1;
  return week;
}

/// 周报文件名：`2026-W33`
String weekKey(DateTime date) =>
    '${date.year}-W${isoWeekNumber(date).toString().padLeft(2, '0')}';

/// 月报文件名：`2026-08`
String monthKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}';

/// 格式化时刻 `HH:mm`
String hhmm(DateTime date) =>
    '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

/// 解析 `HH:mm` 文本 → 今天的对应时刻；非法返回 null。
DateTime? parseHhmm(String text, DateTime now) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(text.trim());
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h > 23 || min > 59) return null;
  return DateTime(now.year, now.month, now.day, h, min);
}
