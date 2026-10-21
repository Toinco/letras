#!/bin/bash
# Crea la llave con la que se firman los APK de release (una sola vez).
#
# IMPORTANTE: guarda una copia de la llave y de las contraseñas en un lugar
# seguro. Si la pierdes, las próximas versiones no se van a poder instalar
# encima de las anteriores (habría que desinstalar la app y perder las
# descargas que no estén exportadas).
#
# Uso (desde la carpeta lyrics_app):
#   bash scripts/crear_llave.sh
set -euo pipefail

# keytool viene con Java; si no hay Java instalado aparte, se usa el que
# trae Android Studio.
KEYTOOL="keytool"
if ! keytool -help >/dev/null 2>&1; then
  KEYTOOL="/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool"
fi
if ! "$KEYTOOL" -help >/dev/null 2>&1; then
  echo "No encontré keytool. Instala Android Studio o un JDK." >&2
  exit 1
fi

KEYSTORE="android/letras-release.jks"
if [ -f "$KEYSTORE" ]; then
  echo "Ya existe $KEYSTORE; no se pisa." >&2
  exit 1
fi

read -r -s -p "Elige una contraseña para la llave (mínimo 6 caracteres): " PASS || true
echo
"$KEYTOOL" -genkeypair -v \
  -keystore "$KEYSTORE" \
  -alias letras \
  -keyalg RSA -keysize 4096 -validity 10000 \
  -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=Letras"

cat > android/key.properties <<PROPS
storeFile=../letras-release.jks
storePassword=$PASS
keyAlias=letras
keyPassword=$PASS
PROPS

echo
echo "Listo: $KEYSTORE y android/key.properties (los dos están en .gitignore)."
echo
echo "Para que GitHub Actions firme los releases, carga estos secretos en"
echo "GitHub > Settings > Secrets and variables > Actions:"
echo "  ANDROID_KEYSTORE_BASE64  -> el resultado de: base64 -i $KEYSTORE | pbcopy"
echo "  ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_PASSWORD -> la contraseña que elegiste"
echo "  ANDROID_KEY_ALIAS        -> letras"
