/// 转录引擎（DESIGN.md §5.4）：OpenAI 兼容 `POST {base}/audio/transcriptions`。
///
/// Groq、火山引擎、阿里通义等均兼容此协议，只需配置 base_url 与 key。
/// 缓存复用逻辑在 CollectService（目标音频同名 `_转写.txt` 存在且 mtime 不早于音频）。
library;

import 'package:dio/dio.dart';

import '../models/settings.dart';

class TranscriptionException implements Exception {
  final String message;
  TranscriptionException(this.message);
  @override
  String toString() => message;
}

class Transcriber {
  final Dio _dio;

  Transcriber({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 30),
            ));

  /// 转录单个音频文件，返回文本。
  Future<String> transcribe({
    required String audioPath,
    required TranscriptSettings config,
  }) async {
    if (config.baseUrl.isEmpty || config.apiKey.isEmpty) {
      throw TranscriptionException('转录接口未配置（设置 → 音频）');
    }
    final url = audioUrl(config.baseUrl);
    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(audioPath),
      'model': config.model,
    });
    try {
      final resp = await _dio.post(
        url,
        data: form,
        options: Options(headers: {
          'Authorization': 'Bearer ${config.apiKey}',
        }),
      );
      final data = resp.data;
      if (data is Map<String, dynamic>) {
        final text = data['text'];
        if (text is String) return text;
        // 火山等兼容实现可能返回 {output: {text}} 或 {result}
        final output = data['output'];
        if (output is Map<String, dynamic> && output['text'] is String) {
          return output['text'] as String;
        }
        throw TranscriptionException('转录响应缺少 text 字段: $data');
      }
      throw TranscriptionException('转录响应格式异常');
    } on DioException catch (e) {
      final detail = e.response?.data;
      throw TranscriptionException('转录失败(${e.response?.statusCode ?? '网络'}): $detail');
    }
  }

  /// OpenAI 兼容端点拼接：已带 /v1 或 /api 直接追加，否则补 /v1
  static String audioUrl(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final suffix = '/audio/transcriptions';
    if (base.contains('/v1') || base.contains('/api')) {
      return '$base$suffix';
    }
    return '$base/v1$suffix';
  }
}
