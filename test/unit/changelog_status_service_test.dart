import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sharedinbox/core/services/changelog_status_service.dart';
import 'package:test/test.dart';

String _compareBody({
  required int aheadBy,
  String? headDate,
}) {
  return jsonEncode({
    'status': aheadBy > 0 ? 'ahead' : 'identical',
    'ahead_by': aheadBy,
    'behind_by': 0,
    'commits': [
      for (var i = 0; i < aheadBy; i++)
        {
          'commit': {
            'committer': {
              // The last entry is the tip of main.
              'date': i == aheadBy - 1 ? headDate : '2026-01-01T00:00:00Z',
            },
          },
        },
    ],
  });
}

void main() {
  group('fetchRepoStatus', () {
    test('reports how many commits main is ahead of the build', () async {
      final client = MockClient((request) async {
        expect(request.url.toString(), contains('/compare/abc1234...main'));
        return http.Response(
          _compareBody(aheadBy: 3, headDate: '2026-08-20T10:00:00Z'),
          200,
        );
      });

      final status = await fetchRepoStatus(client, 'abc1234');

      expect(status.state, RepoStatusState.behind);
      expect(status.behindCount, 3);
      expect(status.latestCommitDate, DateTime.utc(2026, 8, 20, 10));
    });

    test('reports up to date when the build is the tip of main', () async {
      final client = MockClient(
        (request) async => http.Response(_compareBody(aheadBy: 0), 200),
      );

      final status = await fetchRepoStatus(client, 'abc1234');

      expect(status.state, RepoStatusState.upToDate);
      expect(status.behindCount, 0);
    });

    test('maps a non-200 response to unknown', () async {
      final client = MockClient(
        (request) async => http.Response('rate limited', 403),
      );

      final status = await fetchRepoStatus(client, 'abc1234');

      expect(status.state, RepoStatusState.unknown);
    });

    test('maps a network failure to unknown', () async {
      final client = MockClient((request) async {
        throw http.ClientException('boom');
      });

      final status = await fetchRepoStatus(client, 'abc1234');

      expect(status.state, RepoStatusState.unknown);
    });

    test('tolerates a malformed body', () async {
      final client = MockClient(
        (request) async => http.Response('not json', 200),
      );

      final status = await fetchRepoStatus(client, 'abc1234');

      expect(status.state, RepoStatusState.unknown);
    });
  });
}
