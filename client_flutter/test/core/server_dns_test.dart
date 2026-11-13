// ADR-072 — Dart's own connections (LiveKit signalling, the APK download)
// go to Rust's checked address for our host, and TLS still checks our
// certificate for our host name. Real TLS servers on 127.0.0.1.
//
// Certificates are made per run with `openssl` (short-lived: Apple's TLS
// check refuses server certificates valid > 825 days, so the Rust tests'
// long-lived ones in rust/sinhron_net/tests/data don't work here). No
// openssl → the TLS tests are skipped.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sinhron/core/server_dns.dart';

const _host = 'chat.sinhron.test';
String _dir = '';
String? _noOpenssl;

const _cnf = '''
[req]
distinguished_name = dn
[dn]
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
[leaf]
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:\$ENV::SAN
''';

Future<void> _openssl(List<String> args, {String san = 'x'}) async {
  final r = await Process.run('openssl', args, workingDirectory: _dir, environment: {'SAN': san});
  if (r.exitCode != 0) throw StateError('openssl ${args.first}: ${r.stderr}');
}

/// ca.pem; good = chat.sinhron.test from the CA; wrong = another name from
/// the CA; selfsigned = our name, not from the CA. 30 days.
Future<void> _makeCerts() async {
  _dir = (await Directory.systemTemp.createTemp('server_dns_test')).path;
  File('$_dir/o.cnf').writeAsStringSync(_cnf);
  const days = ['-days', '30'];
  await _openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'ca.key', '-out', 'ca.pem', ...days,
      '-subj', '/CN=Sinhron Test CA', '-config', 'o.cnf', '-extensions', 'ca']);
  for (final (name, cn) in [('good', _host), ('wrong', 'isp-portal.example')]) {
    await _openssl(['req', '-newkey', 'rsa:2048', '-nodes', '-keyout', '$name.key', '-out', '$name.csr',
        '-subj', '/CN=$cn', '-config', 'o.cnf'], san: cn);
    await _openssl(['x509', '-req', '-in', '$name.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial',
        '-out', '$name.pem', ...days, '-extfile', 'o.cnf', '-extensions', 'leaf'], san: cn);
  }
  await _openssl(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'selfsigned.key', '-out',
      'selfsigned.pem', ...days, '-subj', '/CN=$_host', '-config', 'o.cnf', '-extensions', 'leaf'], san: _host);
}

SecurityContext _serverCtx(String name) => SecurityContext(withTrustedRoots: false)
  ..useCertificateChain('$_dir/$name.pem')
  ..usePrivateKey('$_dir/$name.key');

SecurityContext _clientCtx() {
  final ctx = SecurityContext(withTrustedRoots: false);
  if (_noOpenssl == null) ctx.setTrustedCertificates('$_dir/ca.pem');
  return ctx;
}

/// An https server on 127.0.0.1 with [cert]: `ok` to GET, a WebSocket echo
/// to an upgrade.
Future<HttpServer> _server(String cert) async {
  final s = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, _serverCtx(cert));
  s.listen((req) async {
    if (WebSocketTransformer.isUpgradeRequest(req)) {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen(ws.add);
    } else {
      req.response.write('ok');
      await req.response.close();
    }
  });
  return s;
}

void main() {
  final asked = <String>[];
  // Rust's answer: our host's checked address is 127.0.0.1 (the system
  // answer was wrong); anything else resolves as usual.
  Future<String?> lookup(String host, int port) async {
    asked.add('$host:$port');
    return host == _host ? '127.0.0.1' : null;
  }

  setUpAll(() async {
    try {
      await _makeCerts();
    } catch (e) {
      _noOpenssl = 'no openssl to make test certificates: $e';
    }
  });
  tearDownAll(() async {
    if (_dir.isNotEmpty) await Directory(_dir).delete(recursive: true);
  });
  setUp(asked.clear);

  Future<String> get(Uri url) async {
    final client = ServerDnsOverrides(lookup).createHttpClient(_clientCtx());
    try {
      final res = await (await client.getUrl(url)).close();
      return await res.transform(utf8.decoder).join();
    } finally {
      client.close(force: true);
    }
  }

  test('our host goes to the checked address, TLS checks our name', () async {
    if (_noOpenssl != null) return markTestSkipped(_noOpenssl!);
    final s = await _server('good');
    addTearDown(() => s.close(force: true));
    expect(await get(Uri.parse('https://$_host:${s.port}/v1/push/info')), 'ok');
    expect(asked, ['$_host:${s.port}']);
  });

  test('a wrong certificate at that address is refused', () async {
    if (_noOpenssl != null) return markTestSkipped(_noOpenssl!);
    final wrong = await _server('wrong'); // valid CA, another name
    addTearDown(() => wrong.close(force: true));
    await expectLater(get(Uri.parse('https://$_host:${wrong.port}/')), throwsA(isA<HandshakeException>()));
    final self = await _server('selfsigned'); // our name, untrusted
    addTearDown(() => self.close(force: true));
    await expectLater(get(Uri.parse('https://$_host:${self.port}/')), throwsA(isA<HandshakeException>()));
  });

  test('a WebSocket (LiveKit signalling) goes through it too', () async {
    if (_noOpenssl != null) return markTestSkipped(_noOpenssl!);
    final s = await _server('good');
    addTearDown(() => s.close(force: true));
    // LiveKit calls WebSocket.connect without a client: dart:io makes its
    // one shared HttpClient on first use, from HttpOverrides.global (set
    // first thing in main). The test runner already made that one, so the
    // client goes in explicitly here.
    final ws = await WebSocket.connect(
      'wss://$_host:${s.port}/rtc',
      customClient: ServerDnsOverrides(lookup).createHttpClient(_clientCtx()),
    );
    final echo = ws.first;
    ws.add('hi');
    expect(await echo, 'hi');
    await ws.close();
    expect(asked, ['$_host:${s.port}']);
  });

  // Status 189 — LiveKit's URL has no port: WebSocket.connect hands the
  // client `https://host:0/rtc`. 0.8.1 connected to port 0 and every call
  // failed ("Can't assign requested address").
  test('a wss URL without a port goes to 443, not port 0', () async {
    final ports = <int>[];
    Future<String?> refuse(String h, int p) async {
      ports.add(p);
      return '127.0.0.1'; // nothing listens on 443 here: refused, fast
    }

    final client = ServerDnsOverrides(refuse).createHttpClient(_clientCtx());
    addTearDown(() => client.close(force: true));
    await expectLater(WebSocket.connect('wss://$_host/rtc', customClient: client), throwsA(anything));
    expect(ports, [443]);
    // The connection the client asks for, port 0, directly.
    ports.clear();
    await expectLater(
      connectVia(Uri.parse('https://$_host:0/rtc'), null, null, lookup: refuse).then((t) => t.socket),
      throwsA(isA<SocketException>()),
    );
    expect(ports, [443]);
  });

  test('other hosts and plain http resolve as usual', () async {
    final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => plain.close(force: true));
    plain.listen((r) => r.response
      ..write('plain')
      ..close());
    expect(await get(Uri.parse('http://127.0.0.1:${plain.port}/')), 'plain');
    expect(asked, isEmpty, reason: 'no lookup for plain http');
    // Not ours: the lookup says null → the usual connection (here: no such name).
    await expectLater(get(Uri.parse('https://nobody.invalid/')), throwsA(isA<SocketException>()));
    expect(asked, ['nobody.invalid:443']);
  });

  test('a failing lookup falls back to the usual connection', () async {
    Future<String?> broken(String h, int p) => Future.error(StateError('rust not ready'));
    final client = ServerDnsOverrides(broken).createHttpClient(_clientCtx());
    addTearDown(() => client.close(force: true));
    await expectLater(client.getUrl(Uri.parse('https://nobody.invalid/')), throwsA(isA<SocketException>()));
  });
}
