// One small HTTP GET for the lookups (song info, lyrics): a timeout, a size limit and
// readable errors. Pure Dart: no Flutter imports.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

/// Sent with every request. MusicBrainz asks for the app name, its version and a contact.
const appUserAgent =
    'KantaheMaker/1.1 ( https://github.com/andrewloable/kantahe-maker )';

class WebGetException implements Exception {
  final String message;
  const WebGetException(this.message);
  @override
  String toString() => message;
}

/// GETs [uri] and returns the status code and the body (UTF-8). Throws
/// [WebGetException] for a timeout, a network error, or more than [maxBytes] of data.
Future<(int, String)> getText(
  Uri uri, {
  Duration timeout = const Duration(seconds: 15),
  int maxBytes = 8 * 1024 * 1024,
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    return await _get(client, uri, maxBytes).timeout(timeout);
  } on TimeoutException {
    throw WebGetException('${uri.host} did not answer in time');
  } on IOException catch (e) {
    throw WebGetException(
      'Could not reach ${uri.host}: ${e is SocketException ? e.message : e}',
    );
  } finally {
    client.close(force: true);
  }
}

Future<(int, String)> _get(HttpClient client, Uri uri, int maxBytes) async {
  final request = await client.getUrl(uri);
  request.headers
    ..set(HttpHeaders.userAgentHeader, appUserAgent)
    ..set(HttpHeaders.acceptHeader, 'application/json');
  final response = await request.close();
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    bytes.add(chunk);
    if (bytes.length > maxBytes) {
      throw WebGetException('${uri.host} sent too much data');
    }
  }
  return (
    response.statusCode,
    utf8.decode(bytes.takeBytes(), allowMalformed: true),
  );
}
