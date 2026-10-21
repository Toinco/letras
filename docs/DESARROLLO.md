# Guía de desarrollo

> Para compilar, correr y publicar la app. La presentación está en el [README](../README.md).

App minimalista estilo Apple Music que detecta automáticamente qué canción
estás escuchando (Spotify, YouTube Music, etc.), muestra su letra con una
animación línea por línea en tiempo real (con traducción rápida al
español), y permite descargarla para verla sin conexión, traducción
incluida. También busca canciones manualmente, se conecta con tu cuenta de
Spotify para ver y descargar las letras de tus "Canciones que te gustan",
y tiene un reconocimiento por micrófono (tipo Shazam) como respaldo.

Todo el código ya está escrito. Esta guía es para dejarlo corriendo en tu
computadora con VS Code, sin necesidad de saber programar en Dart.

## Cómo está armado

- **Detección automática**: código nativo de Android (Kotlin) lee la sesión
  multimedia activa del teléfono (`MediaSessionManager`) usando el permiso
  "Acceso a notificaciones". Funciona con Spotify, YouTube Music y cualquier
  app que reporte su música al sistema. Es gratis, no usa micrófono ni APIs
  externas.
- **Letras**: se buscan en [LRCLIB](https://lrclib.net), una API pública y
  gratuita con letras sincronizadas (con tiempos) en español, inglés y otros
  idiomas. No necesita API key.
- **Reconocimiento por micrófono** (respaldo, para música que suena desde un
  altavoz externo por ejemplo): graba unos segundos de audio y los manda a
  [AudD](https://audd.io), que sí requiere una API key gratuita tuya (tiene
  límite mensual en el plan free).
- **Traducción**: se muestra chiquita debajo de cada línea, usando
  [MyMemory](https://mymemory.translated.net) (gratis, sin API key).
- **Spotify**: login con tu cuenta (OAuth, sin contraseña dentro de la
  app) para ver y descargar las letras de tus canciones con "me gusta".
  Requiere crear una app gratis en el panel de desarrolladores de
  Spotify (ver más abajo).
- **Descargas**: las letras guardadas quedan en archivos locales del
  teléfono (con su traducción, si se pidió), para verlas sin internet.

## Novedades (fines de octubre 2026)

**Letra**
- **Karaoke palabra por palabra** cuando la letra lo trae (LRCLIB con
  `hasWordSync`, LRC mejorado, o NetEase); si no, se estima como antes.
- **Coros** (lo que va entre paréntesis) más chicos y a la derecha.
- **Desenfoque** leve en las líneas lejanas a la actual.
- **Color de la app según la carátula** de lo que suena.
- **Modo karaoke**: solo la línea actual, enorme, para la tele (ícono de
  tele en Reproduciendo).
- En horizontal, Reproduciendo usa toda la pantalla (sin barras).
- Pantalla de arranque oscura e **ícono propio**.

**Fuera de la app** (Ajustes > Letra fuera de la app)
- **Notificación fija** con la línea actual, **widget** de pantalla de
  inicio ("Letra actual") y **burbuja flotante** encima de Spotify.
- La letra de la **próxima canción de la cola** se busca por adelantado.
- **Micrófono sin parar**: va reconociendo canción tras canción
  (menú del micrófono > "Escuchar sin parar"). Cada reconocimiento gasta
  una consulta de AudD.
- Si suenan dos apps a la vez, **chips para elegir cuál seguir**.
- **Desfase por app** (para auriculares Bluetooth), además del de cada canción.

**Fuentes y traducción**
- Si LRCLIB no la tiene: **NetEase** (sincronizada, a veces por palabra) y
  **Genius** (sin sincronizar). Musixmatch no: bloqueó el acceso anónimo.
- **Editor** para corregir una letra y **sincronizarla a mano** tocando
  "Marcar" en cada línea; al guardar ofrece **subirla a LRCLIB**.
- **Pronunciación** (romaji, coreano, cirílico...) debajo de cada línea.
- **Idioma de traducción** a elección, y traducción opcional **con Claude**
  (necesita tu API key de Anthropic; cada canción cuesta centavos).

**Biblioteca**
- Resultados repetidos de LRCLIB **agrupados** ("5 versiones").
- **Playlists** de letras guardadas (mantén apretada una letra).
- **Búsqueda dentro de las letras** en Descargas, que abre con la línea
  resaltada.
- **Exportar/importar** todo en un ZIP (Descargas > menú).
- **Estadísticas**: más escuchadas y horas de letras vistas.
- **Playlists de Spotify** completas, con descarga automática de las
  canciones nuevas (Ajustes > Spotify > Tus playlists; hay que reconectar
  la cuenta una vez para darle el permiso nuevo).
- Las descargas ahora viven en una base **SQLite** (se migran solas la
  primera vez que abres esta versión).

**Técnico**
- Estado con **Riverpod**; la lógica de Reproduciendo vive en
  `NowPlayingController`, fuera de la pantalla.
- Un solo **cliente HTTP con reintentos** y un **registro de errores**
  (Ajustes > Registro de errores, se puede compartir).
- **APK firmado** y **actualizaciones automáticas** desde GitHub Releases.
- **Tests** con respuestas simuladas y **GitHub Actions** (ver abajo).

## Novedades (octubre 2026, primera tanda)

- **Sincronización exacta**: la posición se calcula con el reloj real de
  Android (antes arrancaba atrasada porque Spotify no actualiza la posición
  seguido) y se resincroniza cada 6 s.
- **Karaoke**: la línea actual se ilumina mientras se canta, renglón por
  renglón. Los instrumentales muestran tres puntitos que se van llenando.
- **Líneas completas**: las líneas largas ya no se cortan con "...".
- **Toca una línea** para saltar a ese momento de la canción.
- **Mantén apretada una línea** para copiarla o compartirla como texto o
  como tarjeta-imagen.
- **Ajuste de sincronización por canción** (botón de ecualizador abajo a
  la izquierda), queda guardado.
- **¿Letra equivocada?** Menú "..." → elegir otra entre todos los
  resultados; queda guardada para esa canción.
- **Reproduciendo** ahora tiene fondo con la carátula difuminada, barra de
  progreso y controles también en vertical, y muestra de qué app viene.
- **Traducción con Google** (detecta el idioma sola, cualquier idioma);
  MyMemory queda de respaldo.
- **Historial** de lo último que escuchaste en la pestaña Buscar, y
  búsqueda mientras escribes.
- **Ajustes nuevos**: tamaño de letra, efecto karaoke, pantalla encendida
  y "guardar sola lo que escucho".
- Descargas: lo más reciente primero, se actualiza sola y se puede
  deshacer un borrado.

## 1. Instalar lo necesario (una sola vez)

1. **Flutter SDK**: seguir la guía oficial según tu sistema operativo:
   https://docs.flutter.dev/get-started/install
   Al final, correr `flutter doctor` en una terminal y resolver lo que
   marque en rojo (típicamente falta aceptar licencias de Android con
   `flutter doctor --android-licenses`).
2. **Android Studio**: se usa para el SDK de Android y, si quieres, un
   emulador. Se instala como parte de la guía de arriba.
3. **VS Code**: instalar las extensiones **Flutter** y **Dart** desde el
   ícono de Extensiones (busca "Flutter", la de Dart se instala sola con
   ella).
4. Un **celular Android** con "Depuración por USB" activada (Ajustes >
   Opciones de desarrollador), o un emulador creado desde Android Studio.

## 2. Abrir el proyecto

1. Abre VS Code y haz **Archivo > Abrir carpeta**, selecciona esta carpeta
   (`lyrics_app`).
2. Abre una terminal dentro de VS Code (`Terminal > Nueva terminal`) y
   confirma que estás parado dentro de `lyrics_app`.

## 3. Generar los archivos de Android

Si la carpeta `android/` ya existe en tu copia del proyecto (lo normal),
**omite este paso** — ya está generada y configurada. Esto es solo para
el caso de que la carpeta `android/` no exista (por ejemplo, si la
borraste o clonaste el proyecto de nuevo desde cero).

El código Dart y los archivos nativos ya están escritos
(`MainActivity.kt`, `NowPlayingListenerService.kt`, `AndroidManifest.xml`),
pero faltan piezas que Flutter genera automáticamente (Gradle, íconos,
etc.). Corre, dentro de la carpeta `lyrics_app`:

```
flutter create --platforms=android .
```

(A propósito, sin `--org`: Flutter arma el `applicationId` como
`<org>.<nombre_de_la_carpeta>`, y como la carpeta se llama `lyrics_app`,
pasarle `--org io.letras.app` termina generando el paquete
`io.letras.app.lyrics_app` — distinto al que ya usan nuestros
archivos nativos — y crea un `MainActivity.kt` vacío en la carpeta
equivocada que "gana" por sobre el nuestro. Ya nos pasó una vez.)

Esto completa lo que falta en `android/` sin tocar `lib/`, `pubspec.yaml`
ni los archivos nativos que ya existen. Después, **verifica** que
`android/app/build.gradle.kts` tenga:

```
namespace = "io.letras.app"
...
applicationId = "io.letras.app"
```

Si `flutter create` puso otra cosa ahí, corrígelo a mano (son las dos
únicas líneas que importan).

Después, instala las dependencias del proyecto:

```
flutter pub get
```

## 4. (Opcional) Reconocimiento por micrófono

El token de AudD por defecto no está en el código (el repositorio es
público). Para compilar con él, copia `config/dart_defines.example.json`
a `config/dart_defines.json`, pon tu token, y compila con
`--dart-define-from-file=config/dart_defines.json` (F5 en VS Code ya lo
hace). En GitHub Actions sale del secreto `AUDD_TOKEN`.


Si quieres usar el botón "Reconocer con micrófono":

1. Ve a https://dashboard.audd.io/ y crea una cuenta gratis.
2. Copia tu API token.
3. Corre la app, ve a la pestaña **Ajustes** y pégalo ahí.

Si no lo configuras, el resto de la app funciona igual (detección
automática + búsqueda manual + descargas).

## 5. (Opcional) Conectar Spotify para ver tus favoritos

Para usar la pestaña **Favoritos** (canciones que te gustan en Spotify):

1. Ve a https://developer.spotify.com/dashboard y entra con tu cuenta
   normal de Spotify.
2. **Create app**. Ponle el nombre que quieras (ej. "Letras").
3. En **Redirect URIs** agrega exactamente esta URL:
   ```
   io.letras.app://spotify-callback
   ```
   (Ojo: en algunos paneles de Spotify, si pruebas con `http://127.0.0.1/...`
   el formulario tira "This redirect URI is not secure" y no deja guardar.
   Con este esquema propio no debería pasar — Spotify lo sigue permitiendo
   sin restricción, ver su blog de seguridad de feb. 2025. Android abre la
   app directamente cuando el navegador redirige ahí.)
4. En "Which API/SDKs are you planning to use?" marca **Web API**.
5. Guarda, entra a **Settings** de la app recién creada y copia el
   **Client ID**.
6. Corre la app, ve a **Ajustes**, pega el Client ID en la sección
   "Spotify" y guárdalo.
7. Ve a la pestaña **Favoritos** y toca "Conectar con Spotify": se abre
   el navegador para el login. Al aceptar, la página va a decir que ya
   puedes volver a la app — hazlo manualmente (botón atrás o multitarea).

No hace falta "Client Secret" (la app usa un login más seguro pensado
para apps de celular, que no lo necesita).

## 6. Correr la app

1. Conecta el celular por USB (o abre un emulador desde Android Studio).
2. En VS Code, abajo a la derecha, elige tu dispositivo como target.
3. Pulsa **F5** (o corre `flutter run` en la terminal).
4. La primera vez que abras la app, ve a **Ajustes > Dar acceso** (o a la
   pestaña "Reproduciendo") y activa el permiso de **acceso a
   notificaciones** para que la detección automática funcione. Es un
   permiso especial de Android, se concede una sola vez.
5. Reproduce algo en Spotify o YouTube Music y abre la pestaña "Reproduciendo":
   la letra debería aparecer sola, animándose en sincronía con la canción.

### En la Mac

```
flutter run -d macos --dart-define-from-file=config/dart_defines.json
```

- La detección está en `macos/Runner/NowPlayingBridge.swift`: les pregunta
  por AppleScript a **Spotify** y a **Música** qué suena y en qué segundo va
  (sin abrirlas si están cerradas). Responde los mismos canales que el
  código de Android, así que el lado de Dart es el mismo. macOS pide
  permiso la primera vez ("Letras quiere controlar Spotify"); se revisa en
  Ajustes del Sistema > Privacidad y seguridad > Automatización.
- "Letra fuera de la app" es la línea actual en la barra de menú
  (`MenuBarLyrics.swift`).
- El login de Spotify vuelve con el mismo `io.letras.app://spotify-callback`
  que en Android (registrado en `Info.plist`): no hay que cambiar nada en el
  panel de Spotify.
- Sin sandbox (la app no va a la App Store) y con firma "ad hoc".
- **Xcode 27 + Flutter 3.41**: `flutter build macos --release` falla con
  *"does not contain architectures arm64 x86_64"* (el `lipo` nuevo no
  acepta varias arquitecturas juntas). `flutter run` y las compilaciones
  debug andan. Para una release local, después de ese error:
  ```
  cd macos && xcodebuild -workspace Runner.xcworkspace -scheme Runner \
    -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    SYMROOT="$PWD/../build/macos/Build/Products"
  ```
  En GitHub Actions no pasa (usa otro Xcode).

## Notas y límites

- La detección automática solo funciona con apps que exponen su música al
  sistema Android (Spotify, YouTube Music, Apple Music, etc.), no con
  audio de fuentes externas (radio, altavoz bluetooth de otro dispositivo,
  etc.) — para esos casos está el botón de micrófono.
- No todas las canciones tienen letra sincronizada en LRCLIB; si no la
  encuentra sincronizada, se muestra la letra plana (sin animación línea
  por línea).
- El ícono está en `android/app/src/main/res` (vector adaptable en
  `drawable/ic_launcher_*.xml` + PNG para Android 7). El nombre, en el
  `AndroidManifest.xml` (`android:label`).
- La traducción es automática (MyMemory) y tiene un límite diario gratuito
  por IP; si un día deja de traducir, probablemente sea por eso, y vuelve
  a andar al día siguiente.
- "Descargar todas" en Favoritos puede tardar varios minutos si tienes
  muchas canciones con "me gusta" (hace una búsqueda de letra + traducción
  por canción, con una pequeña pausa entre cada una para no saturar las
  APIs gratuitas). Se puede cancelar a mitad de camino.

## 7. Publicar versiones para tus amigos (APK firmado + actualizaciones)

1. **Una sola vez**, crea la llave de firma:
   ```
   bash scripts/crear_llave.sh
   ```
   Genera `android/letras-release.jks` y `android/key.properties` (no se
   suben a git). **Guarda una copia de la llave y la contraseña**: sin
   ella las versiones nuevas no se instalan encima de las viejas.
2. Sube el proyecto a un repositorio de GitHub y carga los secretos que
   indica el script (GitHub > Settings > Secrets and variables > Actions).
3. Para publicar una versión: sube `version:` en `pubspec.yaml` y crea un tag:
   ```
   git tag v1.1.0 && git push origin v1.1.0
   ```
   GitHub Actions corre los tests, arma el APK firmado y la app de Mac
   (`letras-X.Y.Z-macos.zip`) y los publica en Releases. Pásale a tus amigos el link del APK la primera vez; después,
   en **Ajustes > Buscar actualizaciones**, la app se actualiza sola.

En cada push, el workflow **CI** corre `flutter analyze`, los tests y
compila el APK y la app de Mac. Para correr los tests en tu computadora: `flutter test`.

> Ojo: el primer APK firmado con tu llave no se puede instalar encima de
> uno compilado en modo debug (son firmas distintas). Exporta las
> descargas (Descargas > menú > Exportar), desinstala, instala el nuevo e
> importa.

## Estructura del proyecto

```
lib/
  providers.dart  Todos los servicios como providers de Riverpod
  controllers/    NowPlayingController (todo lo de "Reproduciendo")
  data/           AppDatabase (SQLite)
  models/         Song, LyricLine/LyricWord, LyricsResult
  services/       LRCLIB, NetEase/Genius, LyricsFinder, traducción (Google,
                  MyMemory, Claude), AudD, Spotify, guardado, playlists,
                  estadísticas, copia ZIP, publicar en LRCLIB,
                  actualizaciones, cliente HTTP y registro de errores
  screens/        Pantallas (reproduciendo, karaoke, buscar, descargas,
                  playlists, estadísticas, editor, ajustes, letra...)
  widgets/        SyncedLyricsView (la animación tipo Apple Music), etc.
  utils/          Parser de LRC/Lyricsfile/yrc, coros, normalizar texto
android/app/src/main/kotlin/.../
  MainActivity.kt               Puente Flutter <-> Android (motor en caché)
  MediaSessionBridge.kt         Lee qué suena (MediaSessionManager)
  LiveLyricsService.kt          Notificación con la línea actual
  LyricsWidgetProvider.kt       Widget de pantalla de inicio
  FloatingLyricsBubble.kt       Burbuja flotante
  NowPlayingListenerService.kt  Servicio requerido para el permiso de notificaciones
.github/workflows/  CI (tests en cada push) y Release (APK firmado por tag)
scripts/            crear_llave.sh (llave de firma)
```
