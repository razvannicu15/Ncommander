// Browser sign-in for the Windows build: the provider redirects to a tiny
// server on this PC (loopback), as Google and Microsoft recommend for
// desktop apps.
import 'dart:async';
import 'dart:io';

import '../core/i18n.dart';
import 'native.dart';

/// Opens [build(redirect)] in the browser and waits for the answer.
/// Returns the query parameters plus "redirect" (the URI that was used).
Future<Map<String, String>> loopbackSignIn(Uri Function(String redirect) build, {String host = '127.0.0.1'}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  try {
    final redirect = 'http://$host:${server.port}/';
    await Native.openUrl(build(redirect).toString());
    await for (final req in server.timeout(const Duration(minutes: 5))) {
      final q = req.uri.queryParameters;
      if (!q.containsKey('code') && !q.containsKey('error')) {
        req.response.statusCode = 404;
        await req.response.close();
        continue;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><meta charset="utf-8"><title>Ncommander</title>'
            '<body style="font-family:Segoe UI,sans-serif;display:grid;place-items:center;height:90vh;color:#333">'
            '<div style="text-align:center"><h2>${q.containsKey('code') ? tr('Gata, ești conectat', 'Done, you are signed in') : tr('Autentificarea nu a reușit', 'Sign-in failed')}</h2>'
            '<p>${tr('Poți închide această fereastră și reveni în Ncommander.', 'You can close this window and go back to Ncommander.')}</p></div>');
      await req.response.close();
      return {...q, 'redirect': redirect};
    }
    throw TimeoutException('sign-in');
  } finally {
    await server.close(force: true);
  }
}
