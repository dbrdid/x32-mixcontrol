// X32 MixControl — Behringer X32/M32 리모트 (Flutter).
// ⚠️ 데이터 흐름은 무조건 믹서(콘솔) → 앱. 연결 시 query만, 사용자가 조작할 때만 send.
//   콘솔이 master, 앱은 미러링 리모트. 앱이 콘솔을 멋대로 덮어쓰지 않는다.
// OSC over UDP 10023.
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

const int kPort = 10023;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const X32App());
}

class X32App extends StatelessWidget {
  const X32App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'X32 MixControl',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF13161A),
      ),
      home: const MixerScreen(),
    );
  }
}

// ===== OSC 인코딩/디코딩 =====
List<int> _pad4(List<int> b) {
  final p = (4 - (b.length % 4)) % 4;
  return [...b, ...List.filled(p, 0)];
}

Uint8List oscEncode(String address, List<Object> args) {
  final out = <int>[];
  out.addAll(_pad4([...utf8.encode(address), 0]));
  final tag = StringBuffer(',');
  for (final a in args) {
    tag.write(a is int ? 'i' : (a is double ? 'f' : 's'));
  }
  out.addAll(_pad4([...utf8.encode(tag.toString()), 0]));
  for (final a in args) {
    if (a is int) {
      final bd = ByteData(4)..setInt32(0, a, Endian.big);
      out.addAll(bd.buffer.asUint8List());
    } else if (a is double) {
      final bd = ByteData(4)..setFloat32(0, a, Endian.big);
      out.addAll(bd.buffer.asUint8List());
    } else if (a is String) {
      out.addAll(_pad4([...utf8.encode(a), 0]));
    }
  }
  return Uint8List.fromList(out);
}

class OscMsg {
  final String address;
  final List<Object> args;
  OscMsg(this.address, this.args);
}

OscMsg? oscDecode(Uint8List data) {
  try {
    int i = 0;
    String readStr() {
      final s = i;
      while (i < data.length && data[i] != 0) i++;
      final r = utf8.decode(data.sublist(s, i));
      i++;
      i = (i + 3) & ~3;
      return r;
    }

    final address = readStr();
    if (i >= data.length || data[i] != 0x2c) return OscMsg(address, const []);
    final tags = readStr();
    final args = <Object>[];
    for (int t = 1; t < tags.length; t++) {
      final c = tags[t];
      if (c == 'i') {
        args.add(ByteData.sublistView(data, i, i + 4).getInt32(0, Endian.big));
        i += 4;
      } else if (c == 'f') {
        args.add(ByteData.sublistView(data, i, i + 4).getFloat32(0, Endian.big));
        i += 4;
      } else if (c == 's') {
        args.add(readStr());
      } else if (c == 'b') {
        final sz = ByteData.sublistView(data, i, i + 4).getInt32(0, Endian.big);
        i += 4;
        final e = i + sz;
        if (e > data.length) break;
        args.add(Uint8List.fromList(data.sublist(i, e)));
        i = (e + 3) & ~3;
      } else {
        break;
      }
    }
    return OscMsg(address, args);
  } catch (_) {
    return null;
  }
}

String nn(int c) => c.toString().padLeft(2, '0');

// ===== 변환 =====
String faderDb(double f) {
  if (f <= 0) return '-∞';
  double db;
  if (f >= 0.5) {
    db = f * 40 - 30;
  } else if (f >= 0.25) {
    db = f * 80 - 50;
  } else if (f >= 0.0625) {
    db = f * 160 - 70;
  } else {
    db = f * 480 - 90;
  }
  return db >= 0 ? '+${db.toStringAsFixed(1)}' : db.toStringAsFixed(1);
}

double dbToFader(double db) {
  if (db >= -10) return (db + 30) / 40;
  if (db >= -30) return (db + 50) / 80;
  if (db >= -60) return (db + 70) / 160;
  return ((db + 90) / 480).clamp(0.0, 1.0);
}

Color chColor(int c) {
  switch (c % 8) {
    case 1:
      return const Color(0xFFE53935);
    case 2:
      return const Color(0xFF43A047);
    case 3:
      return const Color(0xFFFDD835);
    case 4:
      return const Color(0xFF1E88E5);
    case 5:
      return const Color(0xFFD81B60);
    case 6:
      return const Color(0xFF00ACC1);
    case 7:
      return const Color(0xFFECEFF1);
    default:
      return const Color(0xFF3A4049);
  }
}

String panLabel(double p) {
  final v = ((p - 0.5) * 200).round();
  if (v == 0) return 'C';
  return v < 0 ? 'L${-v}' : 'R$v';
}

double meterFrac(double lv) {
  if (lv <= 0) return 0;
  final db = 20 * (math.log(lv) / math.ln10);
  return ((db + 60) / 60).clamp(0.0, 1.0);
}

String pkStr(double pk) {
  if (pk <= 0) return '−∞';
  final db = 20 * (math.log(pk) / math.ln10);
  return (db >= 0 ? '+' : '') + db.toStringAsFixed(0);
}

// EQ 정규화(0~1) ↔ 실제값
double eqHz(double x) => 20 * math.pow(1000, x).toDouble();
double eqXfromHz(double hz) => (math.log(hz / 20) / math.ln10) / 3;
double eqGdb(double x) => (x - 0.5) * 30;
double eqXfromG(double db) => db / 30 + 0.5;
double eqQv(double x) => math.pow(10, 1 - 1.523 * x).toDouble();
double eqXfromQ(double q) => (1 - math.log(q) / math.ln10) / 1.523;
String fmtHz(double hz) =>
    hz >= 1000 ? '${(hz / 1000).toStringAsFixed(hz >= 10000 ? 0 : 1)}k' : hz.round().toString();
const List<String> eqTypes = ['LCut', 'LShv', 'PEQ', 'VEQ', 'HShv', 'HCut'];

// 미터 컬러 (톤다운)
const List<Color> kMeterColors = [
  Color(0xFF3A6440),
  Color(0xFF4E8456),
  Color(0xFFB3A85E),
  Color(0xFFB9824E),
  Color(0xFFA85049),
];
const List<double> kMeterStops = [0.0, 0.48, 0.76, 0.90, 1.0];
const List<double> kTicks = [10, 5, 0, -5, -10, -20, -30, -40, -50];

// ===== 모델 =====
class EqBand {
  int t;
  double f, g, q;
  EqBand(this.t, this.f, this.g, this.q);
}

List<EqBand> defaultEq() => [
      EqBand(0, eqXfromHz(80), 0.5, eqXfromQ(2.0)),
      EqBand(2, eqXfromHz(250), 0.5, eqXfromQ(2.0)),
      EqBand(2, eqXfromHz(2500), 0.5, eqXfromQ(2.0)),
      EqBand(4, eqXfromHz(8000), 0.5, eqXfromQ(2.0)),
    ];

class Ch {
  final String kind; // 'ch','auxin','fxrtn','bus'
  final int n;
  String name = '';
  int color = 0;
  double fad;
  bool on = true;
  double pan = 0.5;
  double gain = 0;
  bool eqon = true;
  List<EqBand> eq = defaultEq();
  bool gateOn = false;
  double gateThr = 0.35;
  bool dynOn = false;
  double dynThr = 0.45;
  double lvl = 0, pk = 0, clipUntil = 0;
  Ch(this.kind, this.n, {this.fad = 0.0});
  bool get isDca => kind == 'dca';
  // DCA는 그룹 마스터라 주소가 다르다: /dca/N (패딩 없음, /mix 없음). 나머지는 /kind/NN/mix/...
  String get base => isDca ? '/dca/$n' : '/$kind/${nn(n)}';
  String get faderAddr => isDca ? '$base/fader' : '$base/mix/fader';
  String get onAddr => isDca ? '$base/on' : '$base/mix/on';
  bool get hasGain => kind == 'ch' || kind == 'auxin';
  bool get hasMeter => kind == 'ch';
  bool get hasPan => !isDca; // DCA는 팬 없음(그룹 마스터)
  String get fallbackName {
    switch (kind) {
      case 'ch':
        return 'CH ${nn(n)}';
      case 'auxin':
        return 'AUX ${nn(n)}';
      case 'fxrtn':
        return 'FX ${nn(n)}';
      case 'dca':
        return 'DCA $n';
      default:
        return 'BUS ${nn(n)}';
    }
  }

  String get display => name.isEmpty ? fallbackName : name;
  double get gainMin => kind == 'auxin' ? -18 : -12;
  double get gainMax => kind == 'auxin' ? 18 : 60;
}

class Layer {
  final String label, sub;
  final List<Ch> list;
  const Layer(this.label, this.sub, this.list);
}

// ===== 믹서 화면 =====
class MixerScreen extends StatefulWidget {
  const MixerScreen({super.key});
  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> {
  final _ipCtrl = TextEditingController(text: '192.168.0.64');
  RawDatagramSocket? _socket;
  InternetAddress? _dest;
  Timer? _renew, _decay;
  bool _connected = false;

  late final List<Ch> inputs, auxins, fxrtns, buses, dcas, all;
  late final List<Layer> layers;
  int layerIdx = 0;

  double mainFader = 0.75;
  bool mainOn = true;
  double mainL = 0, mainR = 0, mainPkL = 0, mainPkR = 0, mainClip = 0;

  final _mix = RegExp(r'^/(ch|auxin|fxrtn|bus)/(\d\d)/mix/(fader|on|pan)$');
  final _cfg = RegExp(r'^/(ch|auxin|fxrtn|bus)/(\d\d)/config/(name|color)$');
  final _ha = RegExp(r'^/headamp/(\d\d\d)/gain$');
  final _trim = RegExp(r'^/auxin/(\d\d)/preamp/trim$');
  final _dca = RegExp(r'^/dca/([1-8])/(fader|on)$');
  final _dcaCfg = RegExp(r'^/dca/([1-8])/config/(name|color)$');

  @override
  void initState() {
    super.initState();
    inputs = List.generate(32, (i) => Ch('ch', i + 1));
    auxins = List.generate(8, (i) => Ch('auxin', i + 1));
    fxrtns = List.generate(8, (i) => Ch('fxrtn', i + 1));
    buses = List.generate(16, (i) => Ch('bus', i + 1));
    dcas = List.generate(8, (i) => Ch('dca', i + 1, fad: 0.75));
    all = [...inputs, ...auxins, ...fxrtns, ...buses, ...dcas];
    layers = [
      Layer('CH', '1–8', inputs.sublist(0, 8)),
      Layer('CH', '9–16', inputs.sublist(8, 16)),
      Layer('CH', '17–24', inputs.sublist(16, 24)),
      Layer('CH', '25–32', inputs.sublist(24, 32)),
      Layer('AUX', '1–8', auxins),
      Layer('FX', 'RTN', fxrtns),
      Layer('BUS', '1–8', buses.sublist(0, 8)),
      Layer('BUS', '9–16', buses.sublist(8, 16)),
      Layer('DCA', '1–8', dcas),
    ];
  }

  List<Ch> get cur => layers[layerIdx].list;

  @override
  void dispose() {
    _disconnect();
    _ipCtrl.dispose();
    super.dispose();
  }

  // ===== 연결 =====
  Future<void> _connect() async {
    await _disconnect();
    try {
      _dest = InternetAddress(_ipCtrl.text.trim());
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.listen(_onEvent);
      setState(() => _connected = true);
      _queryAll();
      _send('/xremote');
      _subMeters();
      _renew = Timer.periodic(const Duration(seconds: 8), (_) {
        _send('/xremote');
        _subMeters();
      });
      _decay = Timer.periodic(const Duration(milliseconds: 50), (_) => _decayMeters());
      _snack('연결됨: ${_ipCtrl.text.trim()}');
    } catch (e) {
      _snack('연결 실패: $e');
    }
  }

  Future<void> _disconnect() async {
    _renew?.cancel();
    _renew = null;
    _decay?.cancel();
    _decay = null;
    _socket?.close();
    _socket = null;
    for (final c in all) {
      c.lvl = 0;
      c.pk = 0;
      c.clipUntil = 0;
    }
    mainL = mainR = mainPkL = mainPkR = mainClip = 0;
    if (mounted) setState(() => _connected = false);
  }

  void _send(String addr, [List<Object> args = const []]) {
    final s = _socket, d = _dest;
    if (s == null || d == null) return;
    try {
      s.send(oscEncode(addr, args), d, kPort);
    } catch (_) {}
  }

  void _queryAll() {
    for (final c in all) {
      _send(c.faderAddr);
      _send(c.onAddr);
      if (c.hasPan) _send('${c.base}/mix/pan');
      _send('${c.base}/config/name');
      _send('${c.base}/config/color');
      if (c.kind == 'ch') {
        _send('/headamp/${(c.n - 1).toString().padLeft(3, '0')}/gain');
      } else if (c.kind == 'auxin') {
        _send('${c.base}/preamp/trim');
      }
    }
    _send('/main/st/mix/fader');
    _send('/main/st/mix/on');
  }

  // 미터 구독: /batchsubscribe(별칭)로 여러 뱅크를 동시에 받는다(Cue-View·asm-graphics 등 검증된 패턴).
  //  형식: /batchsubscribe ,ssiii <별칭> <경로> <i0> <i1> <tf>.  tf=2 → 약 100ms 간격.
  //  별칭을 경로 그대로 주면 응답이 그 주소로 와서 어느 뱅크인지 명확해진다. 10초 만료 → _renew(8초)에서 재전송.
  //  /meters/1(96): [0..31]=입력채널 레벨 | /meters/2(49): [0..15]=bus, [22]=main L, [23]=main R | /meters/3(22): [6..13]=aux ret, [14..21]=fx ret
  void _subMeters() {
    _send('/batchsubscribe', ['/meters/1', '/meters/1', 0, 0, 2]);
    _send('/batchsubscribe', ['/meters/2', '/meters/2', 0, 0, 2]);
    _send('/batchsubscribe', ['/meters/3', '/meters/3', 0, 0, 2]);
  }

  Ch? _find(String kind, int n) {
    switch (kind) {
      case 'ch':
        return (n >= 1 && n <= 32) ? inputs[n - 1] : null;
      case 'auxin':
        return (n >= 1 && n <= 8) ? auxins[n - 1] : null;
      case 'fxrtn':
        return (n >= 1 && n <= 8) ? fxrtns[n - 1] : null;
      case 'bus':
        return (n >= 1 && n <= 16) ? buses[n - 1] : null;
      case 'dca':
        return (n >= 1 && n <= 8) ? dcas[n - 1] : null;
    }
    return null;
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    final m = oscDecode(dg.data);
    if (m == null || m.args.isEmpty) return;

    if (m.args.first is Uint8List) {
      _onMeters(m.address, m.args.first as Uint8List);
      return;
    }

    var mt = _mix.firstMatch(m.address);
    if (mt != null) {
      final c = _find(mt.group(1)!, int.parse(mt.group(2)!));
      if (c == null) return;
      final a = m.args.first;
      setState(() {
        switch (mt!.group(3)) {
          case 'fader':
            if (a is double) c.fad = a.clamp(0.0, 1.0);
            break;
          case 'pan':
            if (a is double) c.pan = a.clamp(0.0, 1.0);
            break;
          case 'on':
            c.on = (a is int ? a : (a is double ? a.round() : 1)) != 0;
            break;
        }
      });
      return;
    }

    mt = _cfg.firstMatch(m.address);
    if (mt != null) {
      final c = _find(mt.group(1)!, int.parse(mt.group(2)!));
      if (c == null) return;
      final a = m.args.first;
      setState(() {
        if (mt!.group(3) == 'name' && a is String) {
          c.name = a.trim();
        } else if (mt!.group(3) == 'color') {
          // (mt는 클로저에 캡처된 가변 변수라 promote 불가 → 명시적으로 mt! 단언)
          c.color = a is int ? a : (a is double ? a.round() : 0);
        }
      });
      return;
    }

    mt = _ha.firstMatch(m.address);
    if (mt != null) {
      final idx = int.parse(mt.group(1)!);
      if (idx >= 0 && idx < 32 && m.args.first is double) {
        final ch = inputs[idx];
        // 0~1 정규화 → 실제 dB
        setState(() => ch.gain = (m.args.first as double) * (ch.gainMax - ch.gainMin) + ch.gainMin);
      }
      return;
    }

    mt = _trim.firstMatch(m.address);
    if (mt != null) {
      final c = _find('auxin', int.parse(mt.group(1)!));
      if (c != null && m.args.first is double) {
        // 0~1 정규화 → 실제 dB
        setState(() => c.gain = (m.args.first as double) * (c.gainMax - c.gainMin) + c.gainMin);
      }
      return;
    }

    // DCA 그룹 마스터: /dca/N/fader · /dca/N/on
    mt = _dca.firstMatch(m.address);
    if (mt != null) {
      final c = _find('dca', int.parse(mt.group(1)!));
      if (c == null) return;
      final a = m.args.first;
      setState(() {
        if (mt!.group(2) == 'fader') {
          if (a is double) c.fad = a.clamp(0.0, 1.0);
        } else {
          c.on = (a is int ? a : (a is double ? a.round() : 1)) != 0;
        }
      });
      return;
    }

    // DCA 이름/색상: /dca/N/config/name · /dca/N/config/color
    mt = _dcaCfg.firstMatch(m.address);
    if (mt != null) {
      final c = _find('dca', int.parse(mt.group(1)!));
      if (c == null) return;
      final a = m.args.first;
      setState(() {
        if (mt!.group(2) == 'name' && a is String) {
          c.name = a.trim();
        } else if (mt!.group(2) == 'color') {
          c.color = a is int ? a : (a is double ? a.round() : 0);
        }
      });
      return;
    }

    if (m.address == '/main/st/mix/fader' && m.args.first is double) {
      setState(() => mainFader = (m.args.first as double).clamp(0.0, 1.0));
    } else if (m.address == '/main/st/mix/on') {
      final a = m.args.first;
      setState(() => mainOn = (a is int ? a : (a is double ? a.round() : 1)) != 0);
    }
  }

  void _onMeters(String addr, Uint8List blob) {
    if (blob.length < 8) return;
    final bd = ByteData.sublistView(blob);
    final count = bd.getInt32(0, Endian.little);
    double f(int i) => bd.getFloat32(4 + i * 4, Endian.little).clamp(0.0, 8.0);
    void up(Ch c, double v) {
      c.lvl = v;
      if (v > c.pk) c.pk = v;
      if (v >= 1.0) c.clipUntil = 1.5;
    }

    // 어느 뱅크인지: 응답 주소(별칭) 우선, 없으면 값 개수로 판별. /meters/1=96, /meters/2=49, /meters/3=22.
    final inputsBank = addr.endsWith('/1') || count >= 80;
    final busMainBank = !inputsBank && (addr.endsWith('/2') || (count >= 30 && count < 80));
    final auxFxBank = !inputsBank && !busMainBank && (addr.endsWith('/3') || (count >= 10 && count < 30));

    if (inputsBank) {
      // /meters/1 : 입력 채널 32
      setState(() {
        for (int i = 0; i < 32; i++) {
          if (4 + (i + 1) * 4 > blob.length) break;
          up(inputs[i], f(i));
        }
      });
    } else if (busMainBank) {
      // /meters/2 : 16 bus master + [22]=main L, [23]=main R
      setState(() {
        for (int i = 0; i < 16; i++) {
          if (4 + (i + 1) * 4 > blob.length) break;
          up(buses[i], f(i));
        }
        if (4 + 24 * 4 <= blob.length) {
          mainL = f(22);
          mainR = f(23);
          if (mainL > mainPkL) mainPkL = mainL;
          if (mainR > mainPkR) mainPkR = mainR;
          if (mainL >= 1.0 || mainR >= 1.0) mainClip = 1.5;
        }
      });
    } else if (auxFxBank) {
      // /meters/3 : [0..5]aux send, [6..13]aux return, [14..21]fx return
      setState(() {
        for (int i = 0; i < 8; i++) {
          if (4 + (14 + i + 1) * 4 > blob.length) break;
          up(auxins[i], f(6 + i));
          up(fxrtns[i], f(14 + i));
        }
      });
    }
  }

  void _decayMeters() {
    if (!_connected) return;
    for (final c in all) {
      if (c.lvl > 0) c.lvl = c.lvl < 0.001 ? 0 : c.lvl * 0.86;
      if (c.pk > 0) c.pk = c.pk < 0.001 ? 0 : c.pk * 0.90;
      if (c.clipUntil > 0) c.clipUntil = (c.clipUntil - 0.05).clamp(0.0, 2.0);
    }
    if (mainL > 0) mainL = mainL < 0.001 ? 0 : mainL * 0.86;
    if (mainR > 0) mainR = mainR < 0.001 ? 0 : mainR * 0.86;
    if (mainPkL > 0) mainPkL = mainPkL < 0.001 ? 0 : mainPkL * 0.90;
    if (mainPkR > 0) mainPkR = mainPkR < 0.001 ? 0 : mainPkR * 0.90;
    if (mainClip > 0) mainClip = (mainClip - 0.05).clamp(0.0, 2.0);
    if (mounted) setState(() {});
  }

  // ===== 조작 (앱→믹서: 사용자가 만질 때만) =====
  void _setFader(Ch c, double v) {
    setState(() => c.fad = v.clamp(0.0, 1.0));
    _send(c.faderAddr, [c.fad]);
  }

  void _setPan(Ch c, double v) {
    setState(() => c.pan = v.clamp(0.0, 1.0));
    _send('${c.base}/mix/pan', [c.pan]);
  }

  void _toggleMute(Ch c) {
    final o = !c.on;
    setState(() => c.on = o);
    _send(c.onAddr, [o ? 1 : 0]);
  }

  void _setGain(Ch c, double db) {
    setState(() => c.gain = db.clamp(c.gainMin, c.gainMax));
    // ⚠️ X32 게인/트림은 OSC에서 0.0~1.0 정규화 값(0=최소dB, 1=최대dB)이다.
    // dB를 그대로 보내면 1 이상은 콘솔이 최대(+60dB)로 클램프 → 게인 폭주/하울링.
    final norm = (c.gain - c.gainMin) / (c.gainMax - c.gainMin);
    if (c.kind == 'ch') {
      _send('/headamp/${(c.n - 1).toString().padLeft(3, '0')}/gain', [norm]);
    } else if (c.kind == 'auxin') {
      _send('${c.base}/preamp/trim', [norm]);
    }
  }

  // ▲/▼ 버튼: 1dB씩 정밀 조절(현재값을 정수로 스냅 후 ±1).
  void _stepGain(Ch c, int d) => _setGain(c, (c.gain.round() + d).toDouble());

  void _setMain(double v) {
    setState(() => mainFader = v.clamp(0.0, 1.0));
    _send('/main/st/mix/fader', [mainFader]);
  }

  void _toggleMainMute() {
    final o = !mainOn;
    setState(() => mainOn = o);
    _send('/main/st/mix/on', [o ? 1 : 0]);
  }

  void sendEqBand(Ch c, int i) {
    final b = c.eq[i];
    final band = '${c.base}/eq/${i + 1}';
    _send('$band/type', [b.t]);
    _send('$band/f', [b.f]);
    _send('$band/g', [b.g]);
    _send('$band/q', [b.q]);
  }

  void sendEqOn(Ch c) => _send('${c.base}/eq/on', [c.eqon ? 1 : 0]);
  void sendGate(Ch c) {
    _send('${c.base}/gate/on', [c.gateOn ? 1 : 0]);
    _send('${c.base}/gate/thr', [c.gateThr]);
  }

  void sendDyn(Ch c) {
    _send('${c.base}/dyn/on', [c.dynOn ? 1 : 0]);
    _send('${c.base}/dyn/thr', [c.dynThr]);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  void _openDetail(Ch c) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => DetailPage(ch: c, mixer: this),
      fullscreenDialog: true,
    ));
  }

  bool get connected => _connected;

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            if (!_connected) _banner(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    _layerBar(),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Row(
                        children: [
                          for (final c in cur)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 5),
                                child: _strip(c),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    _mainStrip(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: const Color(0xFF1C2127),
      child: Row(
        children: [
          const Text('🎛️ X32 MixControl',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(width: 14),
          SizedBox(
            width: 150,
            child: TextField(
              controller: _ipCtrl,
              keyboardType: TextInputType.text,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                isDense: true,
                labelText: '콘솔 IP',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _connected ? _disconnect : _connect,
            child: Text(_connected ? '연결 끊기' : '연결'),
          ),
          const SizedBox(width: 10),
          Icon(Icons.circle, size: 11, color: _connected ? const Color(0xFF34C759) : Colors.grey),
          const SizedBox(width: 4),
          Text(_connected ? '연결됨' : '끊김', style: const TextStyle(color: Colors.grey, fontSize: 13)),
          const Spacer(),
          const Text('조절은 위·아래 드래그 · 이름 누르면 상세(EQ)',
              style: TextStyle(fontSize: 11, color: Color(0xFF6B7480))),
        ],
      ),
    );
  }

  Widget _banner() {
    return Container(
      height: 50,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFF191E24),
        border: Border(bottom: BorderSide(color: Color(0xFF11141A))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(color: const Color(0xFF8A94A0), borderRadius: BorderRadius.circular(3)),
            child: const Text('AD', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF0C0E12))),
          ),
          const SizedBox(width: 10),
          const Text('배너 광고 영역 · 연결하면 사라집니다', style: TextStyle(fontSize: 13, color: Color(0xFF79828F))),
        ],
      ),
    );
  }

  Widget _layerBar() {
    final items = <Widget>[];
    for (int i = 0; i < layers.length; i++) {
      if (i == 4 || layers[i].label == 'DCA') {
        items.add(Container(
          margin: const EdgeInsets.fromLTRB(4, 6, 4, 6),
          height: 1,
          color: const Color(0xFF232A33),
        ));
      }
      final active = i == layerIdx;
      items.add(Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: GestureDetector(
          onTap: () => setState(() => layerIdx = i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: active ? const Color(0xFF6C7BD8) : const Color(0xFF1A1F25),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: active ? const Color(0xFF6C7BD8) : const Color(0xFF20262E)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(layers[i].label,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: active ? Colors.white : const Color(0xFF8A94A0))),
                Text(layers[i].sub,
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: active ? const Color(0xFFDFE3FF) : const Color(0xFF5D6671))),
              ],
            ),
          ),
        ),
      ));
    }
    return SizedBox(
      width: 70,
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items)),
    );
  }

  Widget _strip(Ch c) {
    return LayoutBuilder(builder: (ctx, bc) {
      final clip = c.clipUntil > 0;
      // 세로 공간이 좁으면(폰 가로 등) 컴팩트 — 고정요소를 줄여 페이더가 음수/0이 되는 overflow를 막는다.
      final compact = bc.maxHeight.isFinite && bc.maxHeight < 500;
      final gap = compact ? 3.0 : 5.0;
      final gap2 = compact ? 3.0 : 6.0;
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1F25),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xFF20262E)),
        ),
        padding: EdgeInsets.fromLTRB(6, compact ? 7 : 12, 6, compact ? 8 : 14),
        child: Column(
          children: [
            Container(
              height: compact ? 4 : 5,
              margin: const EdgeInsets.symmetric(horizontal: 2),
              decoration: BoxDecoration(color: chColor(c.color), borderRadius: BorderRadius.circular(4)),
            ),
            SizedBox(height: gap),
            GestureDetector(
              onTap: c.isDca ? null : () => _openDetail(c),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: c.lvl > 0.02 ? const Color(0xFF34C759) : const Color(0xFF2A2F36),
                    ),
                  ),
                  Flexible(
                    child: Text(c.display,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ],
              ),
            ),
            if (c.hasGain) ...[
              SizedBox(height: gap),
              _gainSlider(c, compact),
            ],
            SizedBox(height: gap),
            _dbBox(faderDb(c.fad)),
            SizedBox(height: gap2),
            Expanded(child: RepaintBoundary(child: _faderMeter(c))),
            if (!c.isDca) ...[
              const SizedBox(height: 4),
              _pkBox('PK', c.pk, clip),
            ],
            if (c.hasPan) ...[
              SizedBox(height: gap2),
              _panBar(c, compact),
            ],
            SizedBox(height: gap2),
            _muteBtn(c.on, () => _toggleMute(c)),
          ],
        ),
      );
    });
  }

  Widget _gainSlider(Ch c, bool compact) {
    final span = c.gainMax - c.gainMin;
    // ▲/▼ 버튼 = 1dB씩 정밀(메인 조작), 가운데 드래그 = 빠른 대략 이동(둔감).
    final btnH = compact ? 24.0 : 28.0;
    final dragH = compact ? 40.0 : 56.0;
    Widget stepBtn(IconData icon, int d) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _stepGain(c, d),
          child: Container(
            height: btnH,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF2A2410),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFF4A3D1A)),
            ),
            child: Icon(icon, size: btnH - 8, color: const Color(0xFFE0A030)),
          ),
        );
    return Column(
      children: [
        stepBtn(Icons.keyboard_arrow_up, 1),
        const SizedBox(height: 3),
        GestureDetector(
          onVerticalDragUpdate: (d) => _setGain(c, c.gain - d.delta.dy / (dragH * 3) * span),
          child: SizedBox(
            height: dragH,
            child: CustomPaint(
              painter: GainPainter((c.gain - c.gainMin) / span),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('GAIN', style: TextStyle(fontSize: 7, fontWeight: FontWeight.w800, color: Color(0xFF9A8348), letterSpacing: 0.5)),
                    Text('${c.gain >= 0 ? '+' : ''}${c.gain.round()}dB',
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFFE0A030), fontFeatures: [FontFeature('tnum')])),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 3),
        stepBtn(Icons.keyboard_arrow_down, -1),
      ],
    );
  }

  Widget _faderMeter(Ch c) {
    final clip = c.clipUntil > 0;
    return LayoutBuilder(builder: (ctx, bc) {
      final h = bc.maxHeight.isFinite && bc.maxHeight > 40 ? bc.maxHeight : 200.0;
      return GestureDetector(
        onVerticalDragUpdate: (d) => _setFader(c, c.fad - d.delta.dy / h),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _scale(h),
            Expanded(
              child: CustomPaint(
                painter: FaderMeterPainter(
                  fad: c.fad,
                  lvl: c.lvl,
                  pk: c.pk,
                  clip: clip,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _scale(double h) {
    return SizedBox(
      width: 22,
      child: Stack(
        children: [
          for (final db in kTicks)
            Positioned(
              right: 2,
              top: ((1 - dbToFader(db)) * h - 7).clamp(0.0, h - 12),
              child: Text(
                db == 0 ? '0' : db.abs().toStringAsFixed(0),
                style: TextStyle(
                  fontSize: 11,
                  color: db == 0 ? const Color(0xFFAEB6BF) : const Color(0xFF6A7480),
                  fontWeight: db == 0 ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _panBar(Ch c, bool compact) {
    final ph = compact ? 22.0 : 30.0;
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        double v = c.pan - d.delta.dy / 200;
        if ((v - 0.5).abs() < 0.03) v = 0.5;
        _setPan(c, v);
      },
      child: Column(
        children: [
          CustomPaint(
            size: Size(double.infinity, ph),
            painter: PanPainter(c.pan),
            child: SizedBox(height: ph, width: double.infinity),
          ),
          Text(panLabel(c.pan), style: const TextStyle(fontSize: 9, color: Color(0xFF8A94A0), fontFeatures: [FontFeature('tnum')])),
        ],
      ),
    );
  }

  Widget _dbBox(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1115),
        border: Border.all(color: const Color(0xFF2A313B)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text('$text dB',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFCFD6DD), fontFeatures: [FontFeature('tnum')])),
    );
  }

  Widget _pkBox(String label, double pk, bool clip) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      decoration: BoxDecoration(
        color: clip ? const Color(0xFF7A1D18) : const Color(0xFF0E1115),
        border: Border.all(color: clip ? const Color(0xFFFF5252) : const Color(0xFF232A33)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text('$label ${pkStr(pk)}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: clip ? Colors.white : const Color(0xFF9AA4B0), fontFeatures: const [FontFeature('tnum')])),
    );
  }

  Widget _muteBtn(bool on, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: on ? const Color(0xFF2C333D) : const Color(0xFFD13A30),
          padding: const EdgeInsets.symmetric(vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        onPressed: onTap,
        child: Text(on ? 'ON' : 'MUTE', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: on ? const Color(0xFFD7DDE4) : Colors.white)),
      ),
    );
  }

  Widget _mainStrip() {
    return Container(
      width: 92,
      decoration: BoxDecoration(
        color: const Color(0xFF222932),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFF2C3540)),
      ),
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 14),
      child: Column(
        children: [
          Container(
            height: 5,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(color: const Color(0xFFFFCA28), borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(height: 5),
          const Text('MAIN', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFFFCA28), fontSize: 13)),
          const SizedBox(height: 6),
          _dbBox(faderDb(mainFader)),
          const SizedBox(height: 6),
          Expanded(
            child: LayoutBuilder(builder: (ctx, bc) {
              final h = bc.maxHeight.isFinite && bc.maxHeight > 40 ? bc.maxHeight : 200.0;
              return GestureDetector(
                onVerticalDragUpdate: (d) => _setMain(mainFader - d.delta.dy / h),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _scale(h),
                    Expanded(
                      child: CustomPaint(
                        painter: FaderMeterPainter(
                          fad: mainFader,
                          lvl: 0,
                          pk: 0,
                          clip: mainClip > 0,
                          stereoL: mainL,
                          stereoR: mainR,
                          stereoPkL: mainPkL,
                          stereoPkR: mainPkR,
                          stereo: true,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 4),
          _pkBox('L/R', math.max(mainPkL, mainPkR), mainClip > 0),
          const SizedBox(height: 6),
          const Text('ST', style: TextStyle(fontSize: 9, color: Color(0xFF8A94A0))),
          const SizedBox(height: 6),
          _muteBtn(mainOn, _toggleMainMute),
        ],
      ),
    );
  }
}

// ===== CustomPainters =====
class FaderMeterPainter extends CustomPainter {
  final double fad, lvl, pk;
  final bool clip;
  final bool stereo;
  final double stereoL, stereoR, stereoPkL, stereoPkR;
  FaderMeterPainter({
    required this.fad,
    required this.lvl,
    required this.pk,
    required this.clip,
    this.stereo = false,
    this.stereoL = 0,
    this.stereoR = 0,
    this.stereoPkL = 0,
    this.stereoPkR = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6));
    canvas.save();
    canvas.clipRRect(r);
    final grad = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: kMeterColors,
      stops: kMeterStops,
    );
    canvas.drawRect(Offset.zero & size, Paint()..shader = grad.createShader(Offset.zero & size));
    final maskPaint = Paint()..color = const Color(0xFF0C0E12);
    if (stereo) {
      final mh = (1 - meterFrac(stereoL)) * h;
      canvas.drawRect(Rect.fromLTWH(0, 0, w / 2, mh), maskPaint);
      final mhr = (1 - meterFrac(stereoR)) * h;
      canvas.drawRect(Rect.fromLTWH(w / 2, 0, w / 2, mhr), maskPaint);
      canvas.drawRect(Rect.fromLTWH(w / 2 - 0.5, 0, 1, h), Paint()..color = const Color(0x66000000));
    } else {
      final mh = (1 - meterFrac(lvl)) * h;
      canvas.drawRect(Rect.fromLTWH(0, 0, w, mh), maskPaint);
    }
    for (final db in kTicks) {
      final y = (1 - dbToFader(db)) * h;
      final zero = db == 0;
      canvas.drawRect(Rect.fromLTWH(0, y, w, 1), Paint()..color = Color(zero ? 0x9E000000 : 0x73000000));
      canvas.drawRect(Rect.fromLTWH(0, y + 1, w, 1), Paint()..color = Color(zero ? 0x80FFFFFF : 0x38FFFFFF));
    }
    void peakLine(double pkv, double left, double right) {
      if (pkv <= 0) return;
      final y = (1 - meterFrac(pkv)) * h;
      canvas.drawRect(Rect.fromLTWH(left, y - 1, right - left, 2),
          Paint()..color = clip ? const Color(0xFFFF5252) : Colors.white);
    }

    if (stereo) {
      peakLine(stereoPkL, 0, w / 2);
      peakLine(stereoPkR, w / 2, w);
    } else {
      peakLine(pk, 0, w);
    }
    final hy = (1 - fad) * h;
    final capRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(w / 2, hy), width: w + 2, height: 22), const Radius.circular(5));
    canvas.drawRRect(capRect, Paint()..color = const Color(0xFFEFF1FF));
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, hy), width: w - 8, height: 3), const Radius.circular(2)),
        Paint()..color = const Color(0xFF3A4170));
    canvas.restore();
    if (clip) {
      canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = const Color(0xFFFF5252));
    }
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0xFF232A33));
  }

  @override
  bool shouldRepaint(covariant FaderMeterPainter o) => true;
}

class GainPainter extends CustomPainter {
  final double frac;
  GainPainter(this.frac);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0E1115));
    final fh = frac.clamp(0.0, 1.0) * h;
    canvas.drawRect(Rect.fromLTWH(0, h - fh, w, fh), Paint()..color = const Color(0x47E0A030));
    final hy = (1 - frac.clamp(0.0, 1.0)) * h;
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, hy), width: w - 2, height: 13), const Radius.circular(4)),
        Paint()..color = const Color(0xFFE0A030));
    canvas.restore();
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0xFF3A2F1A));
  }

  @override
  bool shouldRepaint(covariant GainPainter o) => o.frac != frac;
}

class PanPainter extends CustomPainter {
  final double pan;
  PanPainter(this.pan);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0E1115));
    final cx = w / 2;
    final fill = Paint()..color = const Color(0xFF3F4A5A);
    if ((pan - 0.5).abs() >= 0.008) {
      final hx = pan * w;
      final path = Path();
      if (pan < 0.5) {
        path.moveTo(hx, 0);
        path.lineTo(cx, h);
        path.lineTo(hx, h);
      } else {
        path.moveTo(cx, 0);
        path.lineTo(hx, h);
        path.lineTo(cx, h);
      }
      path.close();
      canvas.drawPath(path, fill);
    }
    canvas.drawRect(Rect.fromLTWH(cx - 0.5, 3, 1, h - 6), Paint()..color = const Color(0xFF5D6671));
    final hx = pan * w;
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(hx - 2.5, 1, 5, h - 2), const Radius.circular(3)),
        Paint()..color = const Color(0xFF22D3EE));
    canvas.restore();
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0xFF232A33));
  }

  @override
  bool shouldRepaint(covariant PanPainter o) => o.pan != pan;
}

// ===== 채널 상세 (게인 · EQ · 다이내믹) =====
class DetailPage extends StatefulWidget {
  final Ch ch;
  final _MixerScreenState mixer;
  const DetailPage({super.key, required this.ch, required this.mixer});
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with SingleTickerProviderStateMixin {
  int eqSel = 0;
  late final Ticker _ticker;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      setState(() => _t = d.inMilliseconds / 1000.0);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Ch get c => widget.ch;

  @override
  Widget build(BuildContext context) {
    final kindName = c.kind == 'ch'
        ? '입력 채널'
        : c.kind == 'auxin'
            ? 'Aux In (PC 등)'
            : c.kind == 'bus'
                ? '믹스 버스'
                : 'FX 리턴';
    return Scaffold(
      backgroundColor: const Color(0xFF0A0C0F),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: const Color(0xFF1C2127),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Container(width: 5, height: 26, decoration: BoxDecoration(color: chColor(c.color), borderRadius: BorderRadius.circular(3))),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.display, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                      Text('$kindName · ${nn(c.n)}', style: const TextStyle(fontSize: 11, color: Color(0xFF8A94A0))),
                    ],
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF22D3EE),
                      foregroundColor: const Color(0xFF06222A),
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                      elevation: 3,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                    label: const Text('닫기', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: 162, child: SingleChildScrollView(child: _leftCol())),
                    const SizedBox(width: 12),
                    Expanded(child: _eqSect()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectBox({required String title, Widget? action, required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF20262E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFAEB6BF), letterSpacing: 1)),
              const Spacer(),
              if (action != null) action,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _leftCol() {
    return Column(
      children: [
        if (c.hasGain) ...[
          _sectBox(
              title: c.kind == 'auxin' ? 'TRIM' : 'PREAMP',
              child: _knob(
                label: 'GAIN',
                frac: (c.gain - c.gainMin) / (c.gainMax - c.gainMin),
                valText: '${c.gain >= 0 ? '+' : ''}${c.gain.round()}dB',
                onDrag: (dy, h) => widget.mixer._setGain(c, c.gain - dy / h * (c.gainMax - c.gainMin)),
              )),
          const SizedBox(height: 12),
        ],
        _sectBox(
          title: 'DYNAMICS',
          child: Row(
            children: [
              Expanded(child: _dynCol('GATE', c.gateOn, () {
                setState(() => c.gateOn = !c.gateOn);
                widget.mixer.sendGate(c);
              }, c.gateThr, (v) {
                setState(() => c.gateThr = v.clamp(0.0, 1.0));
                widget.mixer.sendGate(c);
              })),
              const SizedBox(width: 12),
              Expanded(child: _dynCol('COMP', c.dynOn, () {
                setState(() => c.dynOn = !c.dynOn);
                widget.mixer.sendDyn(c);
              }, c.dynThr, (v) {
                setState(() => c.dynThr = v.clamp(0.0, 1.0));
                widget.mixer.sendDyn(c);
              })),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dynCol(String label, bool on, VoidCallback toggle, double thr, ValueChanged<double> onThr) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF8A94A0), fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            _toggle(on, toggle),
          ],
        ),
        const SizedBox(height: 8),
        _knob(label: 'THR', frac: thr, valText: '${(-60 + thr * 60).round()}dB', onDrag: (dy, h) => onThr(thr - dy / h)),
      ],
    );
  }

  Widget _toggle(bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(color: on ? const Color(0xFF2E6B3A) : const Color(0xFF2C333D), borderRadius: BorderRadius.circular(6)),
        child: Text(on ? 'ON' : 'OFF', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: on ? Colors.white : const Color(0xFF8A94A0))),
      ),
    );
  }

  Widget _knob({
    required String label,
    required double frac,
    required String valText,
    required void Function(double dy, double h) onDrag,
  }) {
    const h = 96.0;
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF8A94A0), fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        GestureDetector(
          onVerticalDragUpdate: (d) => onDrag(d.delta.dy, h),
          child: CustomPaint(
            size: const Size(38, h),
            painter: GainPainter(frac.clamp(0.0, 1.0)),
            child: const SizedBox(width: 38, height: h),
          ),
        ),
        const SizedBox(height: 5),
        Text(valText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFE6EDF3), fontFeatures: [FontFeature('tnum')])),
      ],
    );
  }

  Widget _eqSect() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF20262E)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text('EQ — 4밴드 PEQ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFAEB6BF), letterSpacing: 1)),
              const SizedBox(width: 6),
              const Text('곡선의 점을 끌어 조절', style: TextStyle(fontSize: 10, color: Color(0xFF5D6671))),
              const Spacer(),
              _toggle(c.eqon, () {
                setState(() => c.eqon = !c.eqon);
                widget.mixer.sendEqOn(c);
              }),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(child: _eqGraph()),
          const SizedBox(height: 10),
          _eqBands(),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _eqTypeRow()),
              const SizedBox(width: 12),
              _eqKnob('FREQ', c.eq[eqSel].f, '${fmtHz(eqHz(c.eq[eqSel].f))}Hz', (dy, h) {
                final b = c.eq[eqSel];
                b.f = (b.f - dy / h).clamp(0.0, 1.0);
                widget.mixer.sendEqBand(c, eqSel);
                setState(() {});
              }),
              const SizedBox(width: 10),
              _eqKnob('GAIN', c.eq[eqSel].g, () {
                final d = eqGdb(c.eq[eqSel].g);
                return (d >= 0 ? '+' : '') + d.toStringAsFixed(1);
              }(), (dy, h) {
                final b = c.eq[eqSel];
                b.g = (b.g - dy / h).clamp(0.0, 1.0);
                widget.mixer.sendEqBand(c, eqSel);
                setState(() {});
              }),
              const SizedBox(width: 10),
              _eqKnob('Q', c.eq[eqSel].q, eqQv(c.eq[eqSel].q).toStringAsFixed(1), (dy, h) {
                final b = c.eq[eqSel];
                b.q = (b.q - dy / h).clamp(0.0, 1.0);
                widget.mixer.sendEqBand(c, eqSel);
                setState(() {});
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _eqGraph() {
    return LayoutBuilder(builder: (ctx, bc) {
      return GestureDetector(
        onPanDown: (e) => _eqPick(e.localPosition, bc),
        onPanUpdate: (e) => _eqMove(e.localPosition, bc),
        child: CustomPaint(
          size: Size(bc.maxWidth, bc.maxHeight),
          painter: EqPainter(ch: c, sel: eqSel, t: _t, connected: widget.mixer.connected),
          child: const SizedBox.expand(),
        ),
      );
    });
  }

  void _eqPick(Offset p, BoxConstraints bc) {
    final w = bc.maxWidth;
    int best = 0;
    double bd = 1e9;
    for (int i = 0; i < c.eq.length; i++) {
      final d = (c.eq[i].f * w - p.dx).abs();
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    setState(() => eqSel = best);
    _eqMove(p, bc);
  }

  void _eqMove(Offset p, BoxConstraints bc) {
    final w = bc.maxWidth, h = bc.maxHeight;
    final b = c.eq[eqSel];
    b.f = (p.dx / w).clamp(0.0, 1.0);
    final denom = (h / 2 - 8).clamp(1.0, double.infinity); // 짧은 화면서 분모 0/음수 방지(드래그 반전 차단)
    final db = ((h / 2 - p.dy) / denom) * 18;
    b.g = eqXfromG(db.clamp(-15.0, 15.0));
    widget.mixer.sendEqBand(c, eqSel);
    setState(() {});
  }

  Widget _eqBands() {
    return Row(
      children: [
        for (int i = 0; i < c.eq.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: GestureDetector(
                onTap: () => setState(() => eqSel = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: i == eqSel ? const Color(0xFF222A33) : const Color(0xFF161B21),
                    borderRadius: BorderRadius.circular(7),
                    border: Border(top: BorderSide(color: i == eqSel ? const Color(0xFF22D3EE) : Colors.transparent, width: 2)),
                  ),
                  child: Column(
                    children: [
                      Text('B${i + 1}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: i == eqSel ? Colors.white : const Color(0xFF8A94A0))),
                      Text(fmtHz(eqHz(c.eq[i].f)), style: const TextStyle(fontSize: 9, color: Color(0xFF7A8492))),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _eqTypeRow() {
    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (int i = 0; i < eqTypes.length; i++)
          GestureDetector(
            onTap: () {
              setState(() => c.eq[eqSel].t = i);
              widget.mixer.sendEqBand(c, eqSel);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: c.eq[eqSel].t == i ? const Color(0xFF22D3EE) : const Color(0xFF161B21),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF2A313B)),
              ),
              child: Text(eqTypes[i], style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.eq[eqSel].t == i ? const Color(0xFF06222A) : const Color(0xFF8A94A0))),
            ),
          ),
      ],
    );
  }

  Widget _eqKnob(String label, double frac, String valText, void Function(double dy, double h) onDrag) {
    const h = 92.0;
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF8A94A0), fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        GestureDetector(
          onVerticalDragUpdate: (d) => onDrag(d.delta.dy, h),
          child: CustomPaint(
            size: const Size(34, h),
            painter: EqKnobPainter(frac.clamp(0.0, 1.0)),
            child: const SizedBox(width: 34, height: h),
          ),
        ),
        const SizedBox(height: 5),
        Text(valText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFE6EDF3), fontFeatures: [FontFeature('tnum')])),
      ],
    );
  }
}

// EQ 곡선 한 밴드의 dB 기여
double bandDb(EqBand b, double fHzVal) {
  final fc = eqHz(b.f), g = eqGdb(b.g), q = eqQv(b.q);
  final r = math.log(fHzVal / fc) / math.ln2;
  switch (b.t) {
    case 2:
    case 3:
      final bw = (1 / q) * 1.1;
      return g * math.exp(-0.5 * math.pow(r / (bw * 0.7 + 0.05), 2));
    case 1:
      return g / (1 + math.pow(fHzVal / fc, 2));
    case 4:
      return g / (1 + math.pow(fc / fHzVal, 2));
    case 0:
      return fHzVal < fc ? math.max(-30.0, 12 * (math.log(fHzVal / fc) / math.ln2)) : 0.0;
    case 5:
      return fHzVal > fc ? math.max(-30.0, 12 * (math.log(fc / fHzVal) / math.ln2)) : 0.0;
  }
  return 0;
}

class EqPainter extends CustomPainter {
  final Ch ch;
  final int sel;
  final double t;
  final bool connected;
  EqPainter({required this.ch, required this.sel, required this.t, required this.connected});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)), Paint()..color = const Color(0xFF0C0E12));
    double x2hz(double x) => 20 * math.pow(1000, x / w).toDouble();
    double db2y(double db) => h / 2 - (db / 18) * (h / 2 - 8);
    final gp = Paint()..color = const Color(0xFF1C232C)..strokeWidth = 1;
    for (final hz in [100.0, 1000.0, 10000.0]) {
      final x = eqXfromHz(hz) * w;
      canvas.drawLine(Offset(x, 0), Offset(x, h), gp);
    }
    for (final db in [-12.0, -6.0, 0.0, 6.0, 12.0]) {
      final y = db2y(db);
      canvas.drawLine(Offset(0, y), Offset(w, y), Paint()..color = db == 0 ? const Color(0xFF33414E) : const Color(0xFF161D24));
    }
    // RTA(실시간 스펙트럼): 채널의 실측 레벨(ch.lvl)에 반응한다. 무신호면 막대를 그리지 않아
    // '예시 그래프'처럼 보이지 않는다(시간 변동은 미세한 질감으로만, 크기는 실측이 지배).
    final amp = meterFrac(ch.lvl);
    if (connected && amp > 0.02) {
      const N = 32;
      for (int i = 0; i < N; i++) {
        final fx = (i + 0.5) / N;
        final fhz = 20 * math.pow(1000, fx).toDouble();
        final tex = 0.85 + 0.15 * math.sin(t * 3.0 + i * 0.8); // ±15% 질감
        double lv = amp * tex * (1 - fx * 0.35);
        if (ch.eqon) {
          double g = 0;
          for (final b in ch.eq) {
            g += bandDb(b, fhz);
          }
          lv *= math.pow(10, (g / 20) * 0.5);
        }
        final x = fx * w, bw = (w / N) * 0.74;
        final bh = math.min(lv, 1.3) * h * 0.46;
        canvas.drawRect(Rect.fromLTWH(x - bw / 2, h - bh, bw, bh),
            Paint()..color = ch.eqon ? const Color(0x3822D3EE) : const Color(0x26879198));
      }
    }
    final path = Path();
    for (double px = 0; px <= w; px += 2) {
      final fhz = x2hz(px);
      double sum = 0;
      for (final b in ch.eq) {
        sum += bandDb(b, fhz);
      }
      final y = db2y(ch.eqon ? sum : 0);
      if (px == 0) {
        path.moveTo(px, y);
      } else {
        path.lineTo(px, y);
      }
    }
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = ch.eqon ? const Color(0xFF22D3EE) : const Color(0xFF3A4651));
    for (int i = 0; i < ch.eq.length; i++) {
      final b = ch.eq[i];
      final x = b.f * w;
      double yd = 0;
      for (final bb in ch.eq) {
        yd += bandDb(bb, eqHz(b.f));
      }
      final y = db2y(ch.eqon ? yd : 0);
      canvas.drawCircle(Offset(x, y), i == sel ? 7 : 5, Paint()..color = i == sel ? const Color(0xFF22D3EE) : const Color(0xFF5B6675));
      final tp = TextPainter(
        text: TextSpan(text: '${i + 1}', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: i == sel ? const Color(0xFF06222A) : const Color(0xFF0C0E12))),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant EqPainter o) => true;
}

class EqKnobPainter extends CustomPainter {
  final double frac;
  EqKnobPainter(this.frac);
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final r = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(r);
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0C0E12));
    final fh = frac * h;
    canvas.drawRect(Rect.fromLTWH(0, h - fh, w, fh), Paint()..color = const Color(0x4D43A047));
    final hy = (1 - frac) * h;
    canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(w / 2, hy), width: w - 4, height: 14), const Radius.circular(5)),
        Paint()..color = const Color(0xFF43A047));
    canvas.restore();
    canvas.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 1..color = const Color(0xFF232A33));
  }

  @override
  bool shouldRepaint(covariant EqKnobPainter o) => o.frac != frac;
}
