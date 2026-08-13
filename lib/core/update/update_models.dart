/// 更新数据模型（issue #5）：检测结果与待安装 manifest。
library;

/// 一次版本检测的可用更新（版本 + 下载地址 + 可选 sha256）
class UpdateInfo {
  /// 无 v 前缀版本（如 0.1.4），比较用
  final String version;
  /// 原始 tag（如 v0.1.4），展示用
  final String tag;
  final String downloadUrl;
  /// 发布方提供的 sha256（无则跳过校验）
  final String? sha256;
  /// 'gitlab' | 'github'
  final String sourceType;

  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.downloadUrl,
    this.sha256,
    required this.sourceType,
  });
}

/// 已下载待安装记录（`<支持目录>/update/manifest.json`）
class UpdateManifest {
  /// 无 v 前缀版本
  final String version;
  final String assetName;
  final String? sha256;
  final String sourceType;

  const UpdateManifest({
    required this.version,
    required this.assetName,
    this.sha256,
    required this.sourceType,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'assetName': assetName,
        'sha256': sha256,
        'sourceType': sourceType,
      };

  factory UpdateManifest.fromJson(Map<String, dynamic> json) => UpdateManifest(
        version: json['version'] as String? ?? '',
        assetName: json['assetName'] as String? ?? '',
        sha256: json['sha256'] as String?,
        sourceType: json['sourceType'] as String? ?? '',
      );
}
