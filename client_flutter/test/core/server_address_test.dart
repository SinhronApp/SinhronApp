// ADR-032 — the server is typed or scanned, never compiled in.

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/server_address.dart';

void main() {
  test('what people type or scan becomes the sync URL', () {
    const ok = {
      'sinhron.example.com': 'wss://sinhron.example.com/v1/sync',
      '  Sinhron.Example.COM  ': 'wss://sinhron.example.com/v1/sync',
      'sinhron.example.com/': 'wss://sinhron.example.com/v1/sync',
      'sinhron.example.com:8443': 'wss://sinhron.example.com:8443/v1/sync',
      'https://sinhron.example.com': 'wss://sinhron.example.com/v1/sync',
      'wss://sinhron.example.com/v1/sync': 'wss://sinhron.example.com/v1/sync',
      'sinhron-server:https://sinhron.example.com': 'wss://sinhron.example.com/v1/sync',
      'SINHRON-SERVER:sinhron.example.com': 'wss://sinhron.example.com/v1/sync',
      'http://192.168.1.20:8080': 'ws://192.168.1.20:8080/v1/sync',
      'ws://localhost:8080/v1/sync': 'ws://localhost:8080/v1/sync',
      'https://[2001:db8::1]': 'wss://[2001:db8::1]/v1/sync',
    };
    for (final e in ok.entries) {
      expect(normalizeServerInput(e.key), e.value, reason: e.key);
    }
  });

  test('anything else is refused', () {
    for (final bad in [
      '',
      '   ',
      'sinhron example.com',
      'ftp://sinhron.example.com',
      'https://user:pw@sinhron.example.com',
      'https://sinhron.example.com/some/page',
      'https://sinhron.example.com/?x=1',
      'sinhron-server:',
      'https://-bad-.example.com',
      'https://300.1.1.1',
      'sinhron-pair:2:abc:def:ghi', // a device-pairing QR, not a server
    ]) {
      expect(normalizeServerInput(bad), isNull, reason: bad);
    }
  });

  test('CN-02 — no TLS only on this machine or a private network', () {
    for (final lan in ['localhost', '127.0.0.1', '10.0.0.2', '172.16.0.1', '172.31.255.255', '192.168.1.20']) {
      expect(normalizeServerInput('http://$lan:8080'), 'ws://$lan:8080/v1/sync', reason: lan);
      expect(normalizeServerInput('ws://$lan/v1/sync'), 'ws://$lan/v1/sync', reason: lan);
    }
    for (final bad in [
      'http://sinhron.example.com',
      'ws://sinhron.example.com/v1/sync',
      'sinhron-server:http://sinhron.example.com',
      'http://8.8.8.8',
      'http://172.15.0.1',
      'http://172.32.0.1',
      'http://192.169.1.1',
      'http://11.0.0.1',
      'http://localhost.example.com',
      'http://10.0.0.2.example.com',
      'http://[2001:db8::1]',
    ]) {
      expect(normalizeServerInput(bad), isNull, reason: bad);
    }
    // A home server by name, over Tailscale, link-local or private IPv6 — as before CN-02.
    for (final home in ['nas', 'sinhron-server', 'nas.local', '100.64.0.1', '100.127.255.254', '169.254.10.20', '[::1]', '[fd00::1]', '[fe80::1]']) {
      expect(normalizeServerInput('http://$home:8080'), 'ws://$home:8080/v1/sync', reason: home);
    }
    for (final bad in ['http://100.63.0.1', 'http://100.128.0.1', 'http://169.253.1.1', 'http://[2606:4700::1]', 'http://nas.local.example.com']) {
      expect(normalizeServerInput(bad), isNull, reason: bad);
    }
    expect(normalizeServerInput('https://8.8.8.8'), 'wss://8.8.8.8/v1/sync');
  });

  test('HTTP base of the sync URL', () {
    expect(httpBaseOf('wss://sinhron.example.com/v1/sync'), 'https://sinhron.example.com');
    expect(httpBaseOf('ws://10.0.0.2:8080/v1/sync'), 'http://10.0.0.2:8080');
  });

  test('host for display (setup screen, My QR code)', () {
    expect(serverHostOf('wss://chat.example.com/v1/sync'), 'chat.example.com');
    expect(serverHostOf('ws://10.0.0.2:8080/v1/sync'), '10.0.0.2:8080');
    expect(serverHostOf(''), '');
  });

  test('only a Sinhron /_healthz counts as a server', () async {
    Uri? asked;
    Future<(int, String)> answer(Uri u, int code, String body) async {
      asked = u;
      return (code, body);
    }

    const url = 'wss://sinhron.example.com/v1/sync';
    expect(
      await checkServer(url, get: (u) => answer(u, 200, '{"status":"ok","service":"sinhron-server","version":"0.1.0"}')),
      ServerCheck.ok,
    );
    expect(asked.toString(), 'https://sinhron.example.com/_healthz');
    expect(await checkServer(url, get: (u) => answer(u, 200, '<html>hi</html>')), ServerCheck.notSinhron);
    expect(await checkServer(url, get: (u) => answer(u, 200, '{"service":"other"}')), ServerCheck.notSinhron);
    expect(await checkServer(url, get: (u) => answer(u, 404, '')), ServerCheck.notSinhron);
    expect(await checkServer(url, get: (u) async => throw const SocketLikeError()), ServerCheck.unreachable);
  });
}

class SocketLikeError implements Exception {
  const SocketLikeError();
}
