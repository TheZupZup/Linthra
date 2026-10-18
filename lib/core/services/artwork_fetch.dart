import 'package:http/http.dart' as http;

import '../sources/subsonic/subsonic_endpoints.dart';

/// Whether a cover [url] may be fetched through a redirect. Not one carrying
/// the legacy Subsonic password: that goes only to the address the user
/// entered. Every other cover loads as it always has.
bool coverMayFollowRedirects(Uri url) =>
    !SubsonicEndpoints.carriesPassword(url);

/// GETs a cover [url] for the artwork caches. One carrying the password is not
/// sent on through a redirect: the 3xx comes back as the answer, and the
/// caller drops it like any other that isn't a 2xx.
Future<http.Response> getCover(http.Client client, Uri url) async {
  if (coverMayFollowRedirects(url)) return client.get(url);
  final http.Request request = http.Request('GET', url)
    ..followRedirects = false;
  return http.Response.fromStream(await client.send(request));
}
