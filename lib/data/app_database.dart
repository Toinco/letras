import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Base de datos SQLite de la app. Reemplaza a los archivos JSON sueltos +
/// la lista en SharedPreferences que se usaban para las descargas: con
/// miles de letras, listar o buscar dentro de ellas era leer miles de
/// archivos; ahora es una consulta.
///
/// Tablas:
/// - `lyrics`: cada letra descargada (el JSON completo + columnas para
///   buscar y ordenar).
/// - `playlists` / `playlist_items`: listas de letras guardadas.
/// - `plays`: cada vez que sonó una canción con letra (para estadísticas).
class AppDatabase {
  static Database? _db;
  static Future<Database>? _opening;

  /// En tests se usa `databaseFactoryFfi` y una ruta en memoria.
  static DatabaseFactory? factoryOverride;
  static String? pathOverride;

  static Future<Database> get instance async {
    if (_db != null) return _db!;
    return _opening ??= _open().then((db) => _db = db);
  }

  static Future<void> closeForTests() async {
    await _db?.close();
    _db = null;
    _opening = null;
  }

  static Future<Database> _open() async {
    final factory = factoryOverride ?? databaseFactory;
    final path = pathOverride ?? p.join(await factory.getDatabasesPath(), 'letras.db');
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE lyrics (
              key TEXT PRIMARY KEY,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              search_text TEXT NOT NULL,
              json TEXT NOT NULL,
              has_synced INTEGER NOT NULL DEFAULT 0,
              spotify_linked INTEGER NOT NULL DEFAULT 0,
              saved_at INTEGER NOT NULL
            )''');
          await db.execute('CREATE INDEX lyrics_saved_at ON lyrics(saved_at)');
          await db.execute('''
            CREATE TABLE playlists (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL,
              created_at INTEGER NOT NULL
            )''');
          await db.execute('''
            CREATE TABLE playlist_items (
              playlist_id INTEGER NOT NULL,
              song_key TEXT NOT NULL,
              position INTEGER NOT NULL,
              PRIMARY KEY (playlist_id, song_key)
            )''');
          await db.execute('''
            CREATE TABLE plays (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              song_id TEXT NOT NULL,
              title TEXT NOT NULL,
              artist TEXT NOT NULL,
              started_at INTEGER NOT NULL,
              lyrics_seconds INTEGER NOT NULL DEFAULT 0
            )''');
          await db.execute('CREATE INDEX plays_song ON plays(song_id)');
        },
      ),
    );
  }
}
