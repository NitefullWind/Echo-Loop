import 'package:flutter_test/flutter_test.dart';
import 'package:echo_loop/features/podcast/anti_bot_detector.dart';

void main() {
  group('isAntiBotChallenge', () {
    test('识别 SiteGround sgcaptcha 验证页', () {
      const body =
          '<html><head><meta http-equiv="refresh" '
          'content="0;/.well-known/sgcaptcha/?r=%2Ffeed%2Fpodcast%2F"></html>';
      expect(isAntiBotChallenge(contentType: 'text/html', body: body), isTrue);
    });

    test('识别 SiteGround robot challenge proof-of-work 页', () {
      const body =
          '<html><head><title>Robot Challenge Screen</title>'
          '<script>const sgchallenge="21:...";</script></head></html>';
      expect(isAntiBotChallenge(contentType: 'text/html', body: body), isTrue);
    });

    test('识别 Cloudflare "Just a moment" 拦截页', () {
      const body = '<html><head><title>Just a moment...</title></head></html>';
      expect(isAntiBotChallenge(contentType: 'text/html', body: body), isTrue);
    });

    test('无 feed 根元素的 HTML 文档视为挑战页', () {
      const body = '<!DOCTYPE html><html><body>Access denied</body></html>';
      expect(isAntiBotChallenge(contentType: 'text/html', body: body), isTrue);
    });

    test('正常 RSS feed 不误判', () {
      const body =
          '<?xml version="1.0"?><rss version="2.0"><channel>'
          '<title>Demo</title><item><guid>1</guid>'
          '<enclosure url="https://a.com/1.mp3" type="audio/mpeg"/>'
          '</item></channel></rss>';
      expect(
        isAntiBotChallenge(contentType: 'application/rss+xml', body: body),
        isFalse,
      );
    });

    test('RSS 正文含 Cloudflare 特征短语时不误判', () {
      const body =
          '<?xml version="1.0"?><rss version="2.0"><channel>'
          '<title>Demo</title><item><guid>1</guid>'
          '<description><![CDATA[Just a moment, please.]]></description>'
          '<enclosure url="https://a.com/1.mp3" type="audio/mpeg"/>'
          '</item></channel></rss>';
      expect(
        isAntiBotChallenge(contentType: 'application/rss+xml', body: body),
        isFalse,
      );
    });

    test('Atom feed 不误判', () {
      const body =
          '<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">'
          '<title>Demo</title></feed>';
      expect(isAntiBotChallenge(contentType: 'text/xml', body: body), isFalse);
    });

    test('内容含 channel 但响应头声明 html 时仍按 feed 处理', () {
      const body = '<rss><channel><title>x</title></channel></rss>';
      expect(isAntiBotChallenge(contentType: 'text/html', body: body), isFalse);
    });
  });
}
