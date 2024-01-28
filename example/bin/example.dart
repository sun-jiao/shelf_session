import 'dart:io' show Cookie, Directory;

import 'package:cryptography/cryptography.dart';
import 'package:mysql_client/mysql_client.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_sessions/shelf_sessions.dart';
import 'package:sqlite3/sqlite3.dart' hide ResultSet;
import 'package:sqlite3/sqlite3.dart' as sqlite show ResultSet;

final algorithm = AesGcm.with256bits();
// This is just an example. Please DO NOT write your secret key in code.
final secretKey = SecretKey('Shelf~Sessions??Shelf!Sessions~!'.codeUnits);

final plainStorage = FileStorage.plain(Directory('shelf_sessions'));
final cryptoStorage = FileStorage.crypto(Directory('shelf_sessions'), algorithm, secretKey);

final db = sqlite3.openInMemory();
final sqliteStorage = SqlStorage('shelf_sessions', db.execute, (sql) {
  final sqlite.ResultSet resultSet = db.select(sql);
  return resultSet;
});
final sqliteCryptoStorage = SqlCryptoStorage('shelf_sessions_crypto', db.execute, (sql) {
  final sqlite.ResultSet resultSet = db.select(sql);
  return resultSet;
  // This is just an example. Please DO NOT write your secret key in code.
}, algorithm, secretKey);

late final SqlStorage mysqlStorage;
late final SqlCryptoStorage mysqlCryptoStorage;

Future<void> createMysqlStorages() async {
  final conn = await MySQLConnection.createConnection(
    host: "127.0.0.1",
    port: 3306,
    userName: "user",
    password: "password",
    databaseName: "shelf_sessions_example", // optional
  );

  await conn.connect();

  mysqlStorage = SqlStorage('shelf_sessions', conn.execute, (sql) async {
    final resultSet = await conn.execute(sql);
    return resultSet.rows.map((row) => {
      'id': row.colByName('id'),
      'expires': row.colByName('expires'),
      'data': row.colByName('data'),
    }).toList();
  });
  await mysqlStorage.createTable();

  mysqlCryptoStorage = SqlCryptoStorage('shelf_sessions_crypto', db.execute, (sql) async {
    final resultSet = await conn.execute(sql);
    return resultSet.rows.map((row) => {
      'id': row.colByName('id'),
      'cipherText': row.colByName('cipherText'),
      'nonce': row.colByName('nonce'),
      'mac': row.colByName('mac'),
    }).toList();
  }, algorithm, secretKey);
  await mysqlCryptoStorage.createTable();
}

void main(List<String> args) async {
  await sqliteCryptoStorage.createTable();
  Session.storage = sqliteCryptoStorage;
  setupJsonSerializer();
  final router = Router();
  router.get('/', _handleHome);
  router.get('/login', _handleLogin);
  router.get('/login/', _handleLogin);
  router.post('/login', _handleLogin);
  router.post('/login/', _handleLogin);
  router.get('/logout', _handleLogout);
  router.get('/logout/', _handleLogout);
  final handler = Cascade().add(router).handler;
  final pipeline = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(cookiesMiddleware())
      .addMiddleware(sessionMiddleware())
      .addHandler(handler);
  const address = 'localhost';
  const port = 8080;
  final server = await io.serve(pipeline, address, port);
  print('Serving at http://${server.address.host}:${server.port}');
}

void setupJsonSerializer() {
  Session.toEncodable = (obj) {
    if (obj is User) {
      return {
        'type': 'User',
        'name': obj.name,
      };
    }
    return obj;
  };
  Session.reviver = (k, v) {
    if (v is Map && v.length == 2 && v['type'] == 'User' && v.containsKey('name')) {
      return User(v['name'] as String);
    }
    return v;
  };
}

const _menu = '''
<a href="/">Home</a><br />
<a href="/login">Log in</a><br />
<a href="/logout">Log out</a><br />''';

Future<Response> _handleHome(Request request) async {
  final userManager = UserManager();
  final user = await userManager.getUser(request);
  var body = '$_menu{{message}}<br />{{cookies}}';
  if (user == null) {
    body = body.replaceAll('{{message}}', 'You are not logged in');
  } else {
    body = body.replaceAll('{{message}}', 'You are logged in as ${user.name}');
  }

  final cookies = request.getCookies();
  body = body.replaceAll(
      '{{cookies}}', cookies.entries.map((e) => '${e.key}: ${e.value}').join('<br />'));
  request.addCookie(Cookie('foo', 'Foo'));
  if (!cookies.containsKey('baz')) {
    request.addCookie(Cookie('baz', 'Baz'));
  } else {
    request.removeCookie(Cookie('baz', ''));
  }

  return _render(body);
}

Future<Response> _handleLogin(Request request) async {
  const html = '''
<form action="" method="post">
<label>Login</label><br />
<input name="login" type="text" /><br />
<label>Password</label><br />
<input name="password" type="password" /><br /><br />
<button>Log in</button>
</form>
''';

  if (request.method == 'GET') {
    return _render(_menu + html);
  }

  final body = await request.readAsString();
  final queryParameters = Uri(query: body).queryParameters;
  final login = queryParameters['login'] ?? ''
    ..trim();
  final password = queryParameters['password'] ?? ''
    ..trim();
  if (login.isEmpty || password.isEmpty) {
    return _render(_menu + html);
  }

  final user = User(login);
  final userManager = UserManager();
  await userManager.setUser(request, user);
  return Response.found('/');
}

Future<Response> _handleLogout(Request request) async {
  await Session.deleteSession(request);
  return Response.found('/');
}

Response _render(String body) {
  return Response.ok(body, headers: {
    'Content-type': 'text/html; charset=UTF-8',
  });
}

class User {
  final String name;

  User(this.name);
}

class UserManager {
  Future<User?> getUser(Request request) async {
    final session = await Session.getSession(request);
    if (session == null) {
      return null;
    }

    final user = session.data['user'];
    if (user is User) {
      return user;
    }

    return null;
  }

  Future<User> setUser(Request request, User user) async {
    var session = await Session.getSession(request);
    session ??= await Session.createSession(request);
    session.data['user'] = user;
    Session.storage.saveSession(session, session.id); // This is required if you use a file storage.
    return user;
  }
}