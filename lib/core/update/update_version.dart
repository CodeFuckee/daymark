/// 版本号比较工具（自动更新用，DESIGN.md §8 补充）。
///
/// release tag（vX.Y.Z）与产物版本（X.Y.Z）语义比较：
/// - 容忍 v 前缀
/// - 不等长段按 0 补位（"1.0" == "1.0.0"）
/// - 忽略 prerelease（-beta）与 build metadata（+1）后缀
/// - 非法数字段按 0 兜底（个人项目，容错优先）
library;

/// 比较两个版本号：a<b 返回 -1，a==b 返回 0，a>b 返回 1。
int compareVersions(String a, String b) {
  final pa = _parse(a);
  final pb = _parse(b);
  for (var i = 0; i < 3; i++) {
    final cmp = _cmpNumeric(pa[i], pb[i]);
    if (cmp != 0) return cmp;
  }
  return 0;
}

/// 数字段字符串比较（避免超大段超出 int 范围被误判为 0）：
/// 去前导零后按长度（位数）比较，等长按字典序。
int _cmpNumeric(String a, String b) {
  String stripZeros(String s) {
    var i = 0;
    while (i < s.length - 1 && s[i] == '0') {
      i++;
    }
    return s.substring(i);
  }

  final x = stripZeros(a);
  final y = stripZeros(b);
  if (x.length != y.length) return x.length < y.length ? -1 : 1;
  return x.compareTo(y);
}

List<String> _parse(String raw) {
  var s = raw.trim();
  if (s.startsWith('v')) s = s.substring(1);
  // 忽略 prerelease 与 build metadata
  s = s.split('-').first.split('+').first;
  final parts = s.split('.').map((e) {
    // 非法段按 '0' 兜底（个人项目，容错优先）
    final trimmed = e.trim();
    return RegExp(r'^\d+$').hasMatch(trimmed) ? trimmed : '0';
  }).toList();
  while (parts.length < 3) {
    parts.add('0');
  }
  return parts;
}
