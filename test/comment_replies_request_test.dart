import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 书评回复的命名空间（`comment_source`）按官方 7.0.9.32 抓包固定在请求里：
/// 书评 501、段评 503。传错不会报错，只会拿到空列表，所以这里把它钉住。
void main() {
  late List<Uri> requests;

  ApiClient buildClient() {
    requests = <Uri>[];
    final transport = MockClient((request) async {
      requests.add(request.url);
      return http.Response.bytes(
        utf8.encode(
          jsonEncode({
            'code': 0,
            'data': {
              'reply_list': <dynamic>[],
              'comment_list_info': {'total': 0},
            },
          }),
        ),
        200,
      );
    });
    addTearDown(transport.close);
    return ApiClient(client: transport, baseUrl: 'http://localhost:9000');
  }

  test('书评回复默认走 501 命名空间，一次取 20 条', () async {
    final api = buildClient();
    await api.commentReplies('book-1', 'comment-1', groupId: 'book-1');

    final url = requests.single;
    expect(url.path, '/api/v1/comments/comment-1/replies');
    expect(url.queryParameters['comment_source'], '501');
    expect(url.queryParameters['count'], '20');
    expect(url.queryParameters['book_id'], 'book-1');
    expect(url.queryParameters['group_id'], 'book-1');
  });

  test('段评回复切到 503 命名空间', () async {
    final api = buildClient();
    await api.commentReplies(
      'book-1',
      'comment-1',
      groupId: 'book-1',
      commentSource: 503,
    );

    expect(requests.single.queryParameters['comment_source'], '503');
  });
}
