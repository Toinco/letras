/// Normaliza texto para comparaciones de búsqueda: minúsculas y sin
/// acentos/diéresis/eñe, así "cancion" encuentra "canción" y viceversa,
/// sin importar mayúsculas.
String normalizeForSearch(String input) {
  var result = input.toLowerCase();
  const accented = 'áàäâãéèëêíìïîóòöôõúùüûñç';
  const plain = 'aaaaaeeeeiiiiooooouuuunc';
  for (var i = 0; i < accented.length; i++) {
    result = result.replaceAll(accented[i], plain[i]);
  }
  return result.trim();
}

final RegExp _featParen =
    RegExp(r'\s*[\(\[]\s*(feat|ft|featuring)\.?[^\)\]]*[\)\]]', caseSensitive: false);
final RegExp _featTrailing =
    RegExp(r'\s+(feat|ft|featuring)\.?\s+.*$', caseSensitive: false);
final RegExp _qualifierParen = RegExp(
  r'\s*[\(\[][^\)\]]*\b(remaster(ed)?|live|acoustic|deluxe|version|edit|mono|stereo|session|demo|bonus track|single|radio edit)\b[^\)\]]*[\)\]]',
  caseSensitive: false,
);
final RegExp _qualifierTrailingDash = RegExp(
  r'\s*-\s*(remaster(ed)?|live|acoustic|deluxe|version|edit|mono|stereo|session|demo|radio edit).*$',
  caseSensitive: false,
);

/// Limpia un título de canción de los sufijos que más suelen romper la
/// búsqueda exacta contra LRCLIB: "(feat. Otro Artista)", "(Live at ...)",
/// "- Remasterizado 2011", "(Radio Edit)", etc. Sirve para reintentar la
/// búsqueda cuando el título "tal cual" (por ejemplo, el que devuelve el
/// reconocimiento de audio o la notificación de la app de música) no
/// encuentra nada.
String cleanTitleForMatching(String title) {
  var t = title;
  t = t.replaceAll(_featParen, '');
  t = t.replaceAll(_featTrailing, '');
  t = t.replaceAll(_qualifierParen, '');
  t = t.replaceAll(_qualifierTrailingDash, '');
  t = t.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  return t;
}

/// Se queda con el primer artista de una lista tipo "Artista A, Artista B
/// & Artista C" o "Artista A feat. Artista B". Sirve para reintentar la
/// búsqueda cuando el artista "completo" no encuentra nada en LRCLIB.
String primaryArtistName(String artist) {
  final first = artist
      .split(RegExp(r'\s*[,&/]\s*|\s+feat\.?\s+|\s+ft\.?\s+|\s+x\s+', caseSensitive: false))
      .first;
  return first.trim();
}
