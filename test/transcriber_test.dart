import 'package:daymark/core/models/settings.dart';
import 'package:daymark/core/transcription/transcriber.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('转录接口 URL 拼接（OpenAI 兼容）', () {
    test('已带 /v1', () {
      expect(
        Transcriber.audioUrl('https://api.openai.com/v1'),
        'https://api.openai.com/v1/audio/transcriptions',
      );
    });

    test('已带 /api（火山引擎）', () {
      expect(
        Transcriber.audioUrl('https://ark.cn-beijing.volces.com/api/v3'),
        'https://ark.cn-beijing.volces.com/api/v3/audio/transcriptions',
      );
    });

    test('裸地址自动补 /v1（通义 compatible-mode）', () {
      expect(
        Transcriber.audioUrl('https://dashscope.aliyuncs.com/compatible-mode'),
        'https://dashscope.aliyuncs.com/compatible-mode/v1/audio/transcriptions',
      );
    });

    test('尾部斜杠清理', () {
      expect(
        Transcriber.audioUrl('https://api.groq.com/openai/v1/'),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
    });
  });

  group('配置校验', () {
    test('未配置接口抛错', () {
      final t = Transcriber();
      expect(
        () => t.transcribe(audioPath: '/tmp/a.m4a', config: TranscriptSettings()),
        throwsA(isA<TranscriptionException>()),
      );
    });
  });
}
