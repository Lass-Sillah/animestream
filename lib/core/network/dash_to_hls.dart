import 'dart:io';
import 'dart:math';

import 'package:animestream/core/app/logging.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// mdk (fvp) cant open DASH manifests (its custom avio breaks ffmpeg's dash demuxer), but plays HLS fine.
/// This converts SegmentTemplate based DASH manifests into fMP4 HLS playlists and serves them from a
/// loopback server. Segment urls stay absolute so the player fetches them directly with its own headers.
class DashToHls {
  DashToHls._();

  static HttpServer? _server;
  static final Map<String, String> _playlists = {};
  static int _counter = 0;

  static bool isDash(String url) => Uri.tryParse(url)?.path.toLowerCase().endsWith('.mpd') ?? false;

  /// Returns a local HLS master playlist url for the given DASH manifest url
  static Future<String> convert(String mpdUrl, {Map<String, String>? headers}) async {
    final res = await http.get(Uri.parse(mpdUrl), headers: headers);
    if (res.statusCode != 200) throw Exception("Couldnt fetch DASH manifest (${res.statusCode})");

    // only one stream plays at a time, drop the old playlists
    _playlists.clear();

    final id = "${_counter++}";
    final files = _buildPlaylists(XmlDocument.parse(res.body), Uri.parse(mpdUrl));
    files.forEach((name, content) => _playlists["/$id/$name"] = content);

    final server = await _ensureServer();
    Logs.player.log("Converted DASH manifest to HLS: ${files.length} playlists");
    return "http://${server.address.address}:${server.port}/$id/master.m3u8";
  }

  static Future<HttpServer> _ensureServer() async {
    if (_server != null) return _server!;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      final body = _playlists[req.uri.path];
      req.response.statusCode = body == null ? HttpStatus.notFound : HttpStatus.ok;
      req.response.headers.contentType = ContentType("application", "vnd.apple.mpegurl");
      if (body != null) req.response.write(body);
      req.response.close();
    });
    return _server = server;
  }

  static Map<String, String> _buildPlaylists(XmlDocument doc, Uri mpdUri) {
    final mpd = doc.rootElement;
    final totalDuration = _parseIsoDuration(mpd.getAttribute('mediaPresentationDuration'));
    final period = mpd.findElements('Period').first;
    Uri base = _resolveBase(mpdUri, mpd);
    base = _resolveBase(base, period);

    final files = <String, String>{};
    final videoVariants = <String>[];
    final audioRenditions = <String>[];
    String? audioCodec;
    int audioBandwidth = 0;
    int audioIndex = 0;

    for (final aset in period.findElements('AdaptationSet')) {
      final asetBase = _resolveBase(base, aset);
      final type = aset.getAttribute('contentType') ?? aset.getAttribute('mimeType')?.split('/').first ?? '';
      final reps = aset.findElements('Representation').toList();

      if (type == 'video') {
        for (final rep in reps) {
          final name = "video_${rep.getAttribute('id')}.m3u8";
          files[name] = _mediaPlaylist(aset, rep, _resolveBase(asetBase, rep), totalDuration);
          final bw = int.tryParse(rep.getAttribute('bandwidth') ?? '') ?? 0;
          final w = rep.getAttribute('width') ?? aset.getAttribute('maxWidth');
          final h = rep.getAttribute('height') ?? aset.getAttribute('maxHeight');
          final codecs = rep.getAttribute('codecs') ?? aset.getAttribute('codecs');
          videoVariants.add([
            "BANDWIDTH=$bw",
            if (w != null && h != null) "RESOLUTION=${w}x$h",
            if (codecs != null) 'CODECS="$codecs{AUDIO_CODEC}"',
            "{AUDIO_GROUP}",
          ].join(',') +
              "\n$name");
        }
      } else if (type == 'audio' && reps.isNotEmpty) {
        // highest bandwidth rep per language
        final rep = reps.reduce((a, b) => (int.tryParse(a.getAttribute('bandwidth') ?? '') ?? 0) >=
                (int.tryParse(b.getAttribute('bandwidth') ?? '') ?? 0)
            ? a
            : b);
        final name = "audio_$audioIndex.m3u8";
        files[name] = _mediaPlaylist(aset, rep, _resolveBase(asetBase, rep), totalDuration);
        final lang = aset.getAttribute('lang') ?? 'und';
        audioRenditions.add('#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="$lang",LANGUAGE="$lang",'
            'DEFAULT=${audioIndex == 0 ? 'YES' : 'NO'},AUTOSELECT=YES,URI="$name"');
        audioCodec ??= rep.getAttribute('codecs') ?? aset.getAttribute('codecs');
        audioBandwidth = max(audioBandwidth, int.tryParse(rep.getAttribute('bandwidth') ?? '') ?? 0);
        audioIndex++;
      }
    }

    if (videoVariants.isEmpty) throw Exception("No video in DASH manifest");

    final hasAudio = audioRenditions.isNotEmpty;
    final master = StringBuffer("#EXTM3U\n#EXT-X-VERSION:7\n");
    audioRenditions.forEach((r) => master.writeln(r));
    for (final v in videoVariants) {
      var variant = v
          .replaceFirst("{AUDIO_CODEC}", hasAudio && audioCodec != null ? ",$audioCodec" : "")
          .replaceFirst(",{AUDIO_GROUP}", hasAudio ? ',AUDIO="aud"' : "");
      // add audio bandwidth to the variant's bandwidth
      variant = variant.replaceFirstMapped(
          RegExp(r'BANDWIDTH=(\d+)'), (m) => "BANDWIDTH=${int.parse(m.group(1)!) + audioBandwidth}");
      master.writeln("#EXT-X-STREAM-INF:$variant");
    }
    files['master.m3u8'] = master.toString();
    return files;
  }

  static String _mediaPlaylist(XmlElement aset, XmlElement rep, Uri base, Duration? total) {
    final tpl = rep.getElement('SegmentTemplate') ?? aset.getElement('SegmentTemplate');
    if (tpl == null) throw Exception("Unsupported DASH manifest (no SegmentTemplate)");

    final repId = rep.getAttribute('id') ?? '';
    final bandwidth = rep.getAttribute('bandwidth') ?? '';
    final timescale = int.tryParse(tpl.getAttribute('timescale') ?? '') ?? 1;
    final startNumber = int.tryParse(tpl.getAttribute('startNumber') ?? '') ?? 1;
    final media = tpl.getAttribute('media')!;
    final init = tpl.getAttribute('initialization');

    // (start time, duration) in timescale units
    final segments = <(int, int)>[];
    final timeline = tpl.getElement('SegmentTimeline');
    if (timeline != null) {
      int t = 0;
      for (final s in timeline.findElements('S')) {
        t = int.tryParse(s.getAttribute('t') ?? '') ?? t;
        final d = int.parse(s.getAttribute('d')!);
        final r = int.tryParse(s.getAttribute('r') ?? '') ?? 0;
        for (int i = 0; i <= r; i++) {
          segments.add((t, d));
          t += d;
        }
      }
    } else {
      final d = int.tryParse(tpl.getAttribute('duration') ?? '');
      if (d == null || total == null) throw Exception("Unsupported DASH manifest (no timeline/duration)");
      final count = (total.inMicroseconds / 1e6 * timescale / d).ceil();
      for (int i = 0; i < count; i++) segments.add((i * d, d));
    }

    String fill(String template, {int? number, int? time}) {
      return template.replaceAllMapped(RegExp(r'\$(RepresentationID|Number|Time|Bandwidth)(%0(\d+)d)?\$'), (m) {
        final value = switch (m.group(1)) {
          'RepresentationID' => repId,
          'Number' => "$number",
          'Time' => "$time",
          _ => bandwidth,
        };
        final pad = int.tryParse(m.group(3) ?? '');
        return pad != null ? value.padLeft(pad, '0') : value;
      }).replaceAll(r'$$', r'$');
    }

    final maxDuration = segments.map((s) => s.$2).fold(0, max) / timescale;
    final out = StringBuffer()
      ..writeln("#EXTM3U")
      ..writeln("#EXT-X-VERSION:7")
      ..writeln("#EXT-X-TARGETDURATION:${maxDuration.ceil()}")
      ..writeln("#EXT-X-PLAYLIST-TYPE:VOD")
      ..writeln("#EXT-X-MEDIA-SEQUENCE:0");
    if (init != null) out.writeln('#EXT-X-MAP:URI="${base.resolve(fill(init))}"');
    for (int i = 0; i < segments.length; i++) {
      final (start, dur) = segments[i];
      out
        ..writeln("#EXTINF:${(dur / timescale).toStringAsFixed(6)},")
        ..writeln(base.resolve(fill(media, number: startNumber + i, time: start)));
    }
    out.writeln("#EXT-X-ENDLIST");
    return out.toString();
  }

  static Uri _resolveBase(Uri base, XmlElement el) {
    final baseUrl = el.getElement('BaseURL')?.innerText.trim();
    return (baseUrl == null || baseUrl.isEmpty) ? base : base.resolve(baseUrl);
  }

  static Duration? _parseIsoDuration(String? iso) {
    if (iso == null) return null;
    final m = RegExp(r'PT(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?').firstMatch(iso);
    if (m == null) return null;
    double part(int i) => double.tryParse(m.group(i) ?? '') ?? 0;
    return Duration(microseconds: ((part(1) * 3600 + part(2) * 60 + part(3)) * 1e6).round());
  }
}
