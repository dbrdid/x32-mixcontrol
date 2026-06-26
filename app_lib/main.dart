// X32 Control — Behringer X32/M32 리모트 (Flutter).
// X32는 OSC 메시지를 UDP 포트 10023으로 주고받아 제어한다.
//  - 채널 페이더: /ch/NN/mix/fader    (float 0.0~1.0, NN=01~32)
//  - 채널 뮤트  : /ch/NN/mix/on       (int 1=켜짐/소리남, 0=뮤트)
//  - 채널 팬    : /ch/NN/mix/pan      (float 0.0~1.0, 0.5=중앙)
//  - 채널 이름  : /ch/NN/config/name  (string)
//  - 채널 색상  : /ch/NN/config/color (int 0~15)
//  - 메인 페이더: /main/st/mix/fader  (float 0.0~1.0)
//  - 메인 뮤트  : /main/st/mix/on     (int 1=소리남, 0=뮤트)
//  - /xremote   : 보내면 X32가 ~10초간 변경값을 보내줌 → 주기적으로 갱신
//  - 주소만(인자 없이) 보내면 현재값을 되돌려줌(연결 시 동기화에 사용)
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';

const int kPort = 10023;
const int kChannels = 32;

void main() => runApp(const X32App());

class X32App extends StatelessWidget {
  const X32App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'X32 MixControl',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF15181C),
      ),
      home: const MixerScreen(),
    );
  }
}

// ===== OSC 인코딩/디코딩 (표준 OSC 1.0) =====
List<int> _pad4(List<int> b) {
  final pad = (4 - (b.length % 4)) % 4;
  return [...b, ...List.filled(pad, 0)];
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
      final start = i;
      while (i < data.length && data[i] != 0) i++;
      final s = utf8.decode(data.sublist(start, i));
      i++; // null
      i = (i + 3) & ~3; // 4바이트 정렬
      return s;
    }

    final address = readStr();
    if (i >= data.length || data[i] != 0x2c) return OscMsg(address, const []); // ',' 없음
    final tags = readStr(); // ",ifs..."
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
        // OSC blob: [int32 BE size][size bytes] → 4바이트 정렬. 미터 데이터가 이리로 온다.
        final size = ByteData.sublistView(data, i, i + 4).getInt32(0, Endian.big);
        i += 4;
        final end = i + size;
        if (end > data.length) break;
        args.add(Uint8List.fromList(data.sublist(i, end)));
        i = (end + 3) & ~3;
      } else {
        break;
      }
    }
    return OscMsg(address, args);
  } catch (_) {
    return null;
  }
}

String _nn(int ch1based) => ch1based.toString().padLeft(2, '0');

// X32 페이더 float(0~1) → dB. 표준 4구간 pseudo-log 변환([-90,+10]dB).
//  f=0.75→0dB, f=1.0→+10dB, f=0.5→-10dB, f=0→-∞
String faderDb(double f) {
  if (f <= 0.0) return '-∞';
  double db;
  if (f >= 0.5) {
    db = f * 40.0 - 30.0;
  } else if (f >= 0.25) {
    db = f * 80.0 - 50.0;
  } else if (f >= 0.0625) {
    db = f * 160.0 - 70.0;
  } else {
    db = f * 480.0 - 90.0;
  }
  final s = db >= 0 ? '+${db.toStringAsFixed(1)}' : db.toStringAsFixed(1);
  return '$s dB';
}

// X32 채널 색상 코드(0~15) → 화면 색. 8~15는 LCD 반전 버전이라 같은 색조로 처리.
Color chColor(int c) {
  switch (c % 8) {
    case 1:
      return const Color(0xFFE53935); // Red
    case 2:
      return const Color(0xFF43A047); // Green
    case 3:
      return const Color(0xFFFDD835); // Yellow
    case 4:
      return const Color(0xFF1E88E5); // Blue
    case 5:
      return const Color(0xFFD81B60); // Magenta
    case 6:
      return const Color(0xFF00ACC1); // Cyan
    case 7:
      return const Color(0xFFECEFF1); // White
    default:
      return const Color(0xFF3A4049); // Off/grey
  }
}

// 팬 float(0~1, 0.5=중앙) → 라벨. L100 ~ C ~ R100
String panLabel(double p) {
  final v = ((p - 0.5) * 200).round();
  if (v == 0) return 'C';
  return v < 0 ? 'L${-v}' : 'R$v';
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
  Timer? _renew;
  bool _connected = false;

  final List<double> _faders = List.filled(kChannels, 0.0);
  final List<bool> _on = List.filled(kChannels, true); // true=소리남, false=뮤트
  final List<double> _pans = List.filled(kChannels, 0.5); // 0.5=중앙
  final List<String> _names = List.filled(kChannels, ''); // 콘솔 채널 이름
  final List<int> _colors = List.filled(kChannels, 0); // 콘솔 색상 코드
  double _mainFader = 0.75;
  bool _mainOn = true;

  // 레벨 미터 (X32 /meters/1 → 입력 32채널, linear 0~1, 1.0=0dBFS)
  final List<double> _levels = List.filled(kChannels, 0.0); // 현재 레벨
  final List<double> _peaks = List.filled(kChannels, 0.0); // peak-hold
  final List<double> _clipHold = List.filled(kChannels, 0.0); // 클립 표시 잔여(초)
  Timer? _meterDecay;

  // 입력 게인 (/headamp/NNN/gain, -12~+60 dB). 채널 1~32 → headamp 0~31(로컬 XLR 입력).
  final List<double> _gains = List.filled(kChannels, 0.0);
  // 메인 L/R 미터 (/meters/5 의 [24]=L, [25]=R)
  double _mainL = 0, _mainR = 0, _mainPkL = 0, _mainPkR = 0, _mainClip = 0;

  @override
  void dispose() {
    _disconnect();
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    await _disconnect();
    final ip = _ipCtrl.text.trim();
    try {
      _dest = InternetAddress(ip);
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.listen(_onEvent);
      setState(() => _connected = true);
      _queryAll();
      _send('/xremote');
      _subscribeMeters();
      _renew = Timer.periodic(const Duration(seconds: 8), (_) {
        _send('/xremote');
        _subscribeMeters();
      });
      _meterDecay = Timer.periodic(const Duration(milliseconds: 50), (_) => _decayMeters());
      _snack('연결됨: $ip');
    } catch (e) {
      _snack('연결 실패: $e');
    }
  }

  Future<void> _disconnect() async {
    _renew?.cancel();
    _renew = null;
    _meterDecay?.cancel();
    _meterDecay = null;
    _socket?.close();
    _socket = null;
    for (int i = 0; i < kChannels; i++) {
      _levels[i] = 0;
      _peaks[i] = 0;
      _clipHold[i] = 0;
    }
    _mainL = _mainR = _mainPkL = _mainPkR = _mainClip = 0;
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
    for (int c = 1; c <= kChannels; c++) {
      final nn = _nn(c);
      _send('/ch/$nn/mix/fader');
      _send('/ch/$nn/mix/on');
      _send('/ch/$nn/mix/pan');
      _send('/ch/$nn/config/name');
      _send('/ch/$nn/config/color');
      _send('/headamp/${(c - 1).toString().padLeft(3, '0')}/gain');
    }
    _send('/main/st/mix/fader');
    _send('/main/st/mix/on');
  }

  // X32 미터 구독: /meters ,si "/meters/1" <factor>. factor=2 → 100ms 간격.
  // 콘솔은 ~10초 후 멈추므로 _renew(8초)에서 다시 보낸다.
  void _subscribeMeters() {
    _send('/meters', ['/meters/1', 2]); // 입력 채널 32개 (96 floats)
    _send('/meters', ['/meters/5', 0, 0]); // 채널/그룹/메인 VU (27 floats) — 메인 L/R용
  }

  // /meters/1 blob = [int32 LE count][float32 LE × count].
  //  [0..31]=입력채널 레벨, [32..63]=게이트 GR, [64..95]=다이내믹 GR (뒤 64개는 무시).
  //  값: 선형 0~1 (1.0=0dBFS, 헤드룸 8.0=+18dBFS).
  void _onMeters(Uint8List blob) {
    if (blob.length < 8) return;
    final bd = ByteData.sublistView(blob);
    final count = bd.getInt32(0, Endian.little);
    double f(int i) => bd.getFloat32(4 + i * 4, Endian.little).clamp(0.0, 8.0);
    if (count >= 90) {
      // /meters/1 (96 floats): [0..31] = 입력 채널 레벨
      setState(() {
        for (int i = 0; i < kChannels; i++) {
          if (4 + (i + 1) * 4 > blob.length) break;
          final v = f(i);
          _levels[i] = v;
          if (v > _peaks[i]) _peaks[i] = v;
          if (v >= 1.0) _clipHold[i] = 1.5; // 0dBFS 이상 → 1.5초 클립 표시
        }
      });
    } else if (count >= 26) {
      // /meters/5 (27 floats): [24]=메인 L, [25]=메인 R
      if (4 + 26 * 4 > blob.length) return;
      setState(() {
        _mainL = f(24);
        _mainR = f(25);
        if (_mainL > _mainPkL) _mainPkL = _mainL;
        if (_mainR > _mainPkR) _mainPkR = _mainR;
        if (_mainL >= 1.0 || _mainR >= 1.0) _mainClip = 1.5;
      });
    }
  }

  // 50ms마다: 레벨/peak 자연 감쇠, 클립 표시 시간 차감.
  void _decayMeters() {
    if (!_connected) return;
    for (int i = 0; i < kChannels; i++) {
      if (_levels[i] > 0) _levels[i] = _levels[i] < 0.001 ? 0.0 : _levels[i] * 0.86;
      if (_peaks[i] > 0) _peaks[i] = _peaks[i] < 0.001 ? 0.0 : _peaks[i] * 0.90;
      if (_clipHold[i] > 0) _clipHold[i] = (_clipHold[i] - 0.05).clamp(0.0, 2.0);
    }
    if (_mainL > 0) _mainL = _mainL < 0.001 ? 0.0 : _mainL * 0.86;
    if (_mainR > 0) _mainR = _mainR < 0.001 ? 0.0 : _mainR * 0.86;
    if (_mainPkL > 0) _mainPkL = _mainPkL < 0.001 ? 0.0 : _mainPkL * 0.90;
    if (_mainPkR > 0) _mainPkR = _mainPkR < 0.001 ? 0.0 : _mainPkR * 0.90;
    if (_mainClip > 0) _mainClip = (_mainClip - 0.05).clamp(0.0, 2.0);
    if (mounted) setState(() {});
  }

  // 미터 높이 비율: linear level → dBFS(-60~0) → 0~1. 1.0=0dBFS=꼭대기.
  double _meterFrac(double lv) {
    if (lv <= 0.0) return 0.0;
    final db = 20 * (math.log(lv) / math.ln10);
    return ((db + 60) / 60).clamp(0.0, 1.0);
  }

  // 페이더 게인 dB → 페이더 위치(0~1). faderDb 의 역함수(눈금 위치 계산용).
  double _dbToFader(double db) {
    if (db >= -10) return (db + 30) / 40;
    if (db >= -30) return (db + 50) / 80;
    if (db >= -60) return (db + 70) / 160;
    return ((db + 90) / 480).clamp(0.0, 1.0);
  }

  // peak 의 dBFS 표시 문자열
  String _pkStr(double pk) {
    if (pk <= 0) return '−∞';
    final db = 20 * (math.log(pk) / math.ln10);
    return (db >= 0 ? '+' : '') + db.toStringAsFixed(0);
  }

  void _onEvent(RawSocketEvent e) {
    if (e != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    final m = oscDecode(dg.data);
    if (m == null || m.args.isEmpty) return;

    // 레벨 미터: blob 인자가 오면 /meters 데이터로 간주
    if (m.args.first is Uint8List) {
      _onMeters(m.args.first as Uint8List);
      return;
    }

    // 입력 게인 (/headamp/NNN/gain)
    final ha = RegExp(r'^/headamp/(\d\d\d)/gain$').firstMatch(m.address);
    if (ha != null) {
      final idx = int.parse(ha.group(1)!);
      if (idx >= 0 && idx < kChannels && m.args.first is double) {
        setState(() => _gains[idx] = m.args.first as double);
      }
      return;
    }

    // 채널 mix: fader / on / pan
    final mix = RegExp(r'^/ch/(\d\d)/mix/(fader|on|pan)$').firstMatch(m.address);
    if (mix != null) {
      final idx = int.parse(mix.group(1)!) - 1;
      if (idx < 0 || idx >= kChannels) return;
      final a = m.args.first;
      setState(() {
        switch (mix.group(2)) {
          case 'fader':
            if (a is double) _faders[idx] = a.clamp(0.0, 1.0);
            break;
          case 'pan':
            if (a is double) _pans[idx] = a.clamp(0.0, 1.0);
            break;
          case 'on':
            _on[idx] = (a is int ? a : (a is double ? a.round() : 1)) != 0;
            break;
        }
      });
      return;
    }

    // 채널 config: name / color
    final cfg = RegExp(r'^/ch/(\d\d)/config/(name|color)$').firstMatch(m.address);
    if (cfg != null) {
      final idx = int.parse(cfg.group(1)!) - 1;
      if (idx < 0 || idx >= kChannels) return;
      final a = m.args.first;
      setState(() {
        if (cfg.group(2) == 'name' && a is String) {
          _names[idx] = a.trim();
        } else if (cfg.group(2) == 'color') {
          _colors[idx] = a is int ? a : (a is double ? a.round() : 0);
        }
      });
      return;
    }

    // 메인 스트립
    if (m.address == '/main/st/mix/fader' && m.args.first is double) {
      setState(() => _mainFader = (m.args.first as double).clamp(0.0, 1.0));
    } else if (m.address == '/main/st/mix/on') {
      final a = m.args.first;
      setState(() => _mainOn = (a is int ? a : (a is double ? a.round() : 1)) != 0);
    }
  }

  void _setFader(int idx, double v) {
    setState(() => _faders[idx] = v);
    _send('/ch/${_nn(idx + 1)}/mix/fader', [v]);
  }

  void _setPan(int idx, double v) {
    setState(() => _pans[idx] = v);
    _send('/ch/${_nn(idx + 1)}/mix/pan', [v]);
  }

  void _toggleMute(int idx) {
    final newOn = !_on[idx];
    setState(() => _on[idx] = newOn);
    _send('/ch/${_nn(idx + 1)}/mix/on', [newOn ? 1 : 0]);
  }

  void _setMain(double v) {
    setState(() => _mainFader = v);
    _send('/main/st/mix/fader', [v]);
  }

  void _setGain(int idx, double db) {
    setState(() => _gains[idx] = db);
    _send('/headamp/${idx.toString().padLeft(3, '0')}/gain', [db]);
  }

  void _toggleMainMute() {
    final newOn = !_mainOn;
    setState(() => _mainOn = newOn);
    _send('/main/st/mix/on', [newOn ? 1 : 0]);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          for (int i = 0; i < kChannels; i++) _channelStrip(i),
                        ],
                      ),
                    ),
                  ),
                  Container(width: 1, color: const Color(0xFF2A2F36)),
                  _mainStrip(),
                ],
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
          const Text('🎛️ X32', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(width: 16),
          SizedBox(
            width: 180,
            child: TextField(
              controller: _ipCtrl,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '콘솔 IP',
                hintText: '192.168.0.64',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: _connected ? _disconnect : _connect,
            child: Text(_connected ? '연결 끊기' : '연결'),
          ),
          const SizedBox(width: 12),
          Icon(Icons.circle, size: 12, color: _connected ? Colors.green : Colors.grey),
          const SizedBox(width: 4),
          Text(_connected ? '연결됨' : '끊김', style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }

  // 세로 페이더 — 부모가 준 높이에 정확히 맞춰 길이 자동 조절(작은 화면도 안 깨짐).
  Widget _verticalFader(double value, ValueChanged<double> onChanged) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final h = c.maxHeight.isFinite && c.maxHeight > 60 ? c.maxHeight : 160.0;
        return RotatedBox(
          quarterTurns: 3,
          child: SizedBox(width: h, child: Slider(value: value, onChanged: onChanged)),
        );
      },
    );
  }

  // 레벨 미터 바(세로) — 컬러 그라데이션 + peak선 + clip 테두리.
  Widget _meterBar(double lv, double peak, bool clip) {
    return LayoutBuilder(
      builder: (ctx, c) {
        final h = c.maxHeight.isFinite && c.maxHeight > 20 ? c.maxHeight : 120.0;
        final maskH = h * (1 - _meterFrac(lv));
        final peakY = (h * _meterFrac(peak)).clamp(0.0, h - 2);
        return SizedBox(
          width: 11,
          height: h,
          child: Stack(
            children: [
              // 컬러 그라데이션 (아래 초록 → 위 빨강)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: const LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xFF2E7D32), Color(0xFF43A047), Color(0xFFFDD835), Color(0xFFFB8C00), Color(0xFFE53935)],
                      stops: [0.0, 0.52, 0.78, 0.9, 1.0],
                    ),
                  ),
                ),
              ),
              // 마스크: 레벨 위쪽을 덮어 가림
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  width: 11,
                  height: maskH,
                  decoration: BoxDecoration(color: const Color(0xFF0C0E12), borderRadius: BorderRadius.circular(4)),
                ),
              ),
              // 클립 테두리
              if (clip)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: const Color(0xFFFF5252), width: 2),
                    ),
                  ),
                ),
              // peak 선
              if (peak > 0)
                Positioned(
                  bottom: peakY,
                  left: 0,
                  right: 0,
                  child: Container(height: 2, color: clip ? const Color(0xFFFF5252) : Colors.white),
                ),
            ],
          ),
        );
      },
    );
  }

  // 페이더 dB 눈금자
  Widget _scale() {
    const ticks = [10.0, 5.0, 0.0, -5.0, -10.0, -20.0, -30.0, -40.0, -50.0];
    return LayoutBuilder(
      builder: (ctx, c) {
        final h = c.maxHeight.isFinite && c.maxHeight > 20 ? c.maxHeight : 120.0;
        return SizedBox(
          width: 20,
          height: h,
          child: Stack(
            children: [
              for (final db in ticks)
                Positioned(
                  right: 2,
                  top: ((1 - _dbToFader(db)) * h - 6).clamp(0.0, h - 10),
                  child: Text(
                    db == 0 ? '0' : db.abs().toStringAsFixed(0),
                    style: TextStyle(
                      fontSize: 8,
                      color: db == 0 ? const Color(0xFFAEB6BF) : const Color(0xFF5D6671),
                      fontWeight: db == 0 ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // 입력 게인 행 (채널 위쪽)
  Widget _gainRow(int idx) {
    final g = _gains[idx];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('GAIN', style: TextStyle(fontSize: 8, color: Color(0xFF8A94A0), letterSpacing: 0.5)),
              Text('${g >= 0 ? '+' : ''}${g.toStringAsFixed(0)} dB',
                  style: const TextStyle(fontSize: 9, color: Color(0xFFE0A030), fontWeight: FontWeight.w700)),
            ],
          ),
          SizedBox(
            height: 16,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                activeTrackColor: const Color(0xFFE0A030),
                inactiveTrackColor: const Color(0xFF2A2F36),
                thumbColor: const Color(0xFFE0A030),
              ),
              child: Slider(
                value: g.clamp(-12.0, 60.0),
                min: -12,
                max: 60,
                onChanged: (v) => _setGain(idx, v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 값 박스 (레벨 dB)
  Widget _dbBox(String text) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(vertical: 2),
      width: 62,
      decoration: BoxDecoration(
        color: const Color(0xFF0E1115),
        border: Border.all(color: const Color(0xFF2A313B)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFCFD6DD), fontFeatures: [FontFeature('tnum')])),
    );
  }

  // PK 박스 (peak dBFS)
  Widget _pkBox(String label, double pk, bool clip) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(vertical: 2),
      width: 66,
      decoration: BoxDecoration(
        color: clip ? const Color(0xFF7A1D18) : const Color(0xFF0E1115),
        border: Border.all(color: clip ? const Color(0xFFFF5252) : const Color(0xFF232A33)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text('$label ${_pkStr(pk)}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: clip ? Colors.white : const Color(0xFF9AA4B0), fontFeatures: const [FontFeature('tnum')])),
    );
  }

  // 작은 가로 팬 슬라이더
  Widget _panSlider(int idx) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
        activeTrackColor: const Color(0xFF5C6BC0),
        inactiveTrackColor: const Color(0xFF2A2F36),
      ),
      child: Slider(
        value: _pans[idx],
        onChanged: (v) => _setPan(idx, v),
      ),
    );
  }

  Widget _channelStrip(int idx) {
    final on = _on[idx];
    final name = _names[idx].isEmpty ? 'CH ${_nn(idx + 1)}' : _names[idx];
    return Container(
      width: 84,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1F25),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF20262E)),
      ),
      child: Column(
        children: [
          // 색상 띠
          Container(
            height: 6,
            margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            decoration: BoxDecoration(color: chColor(_colors[idx]), borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(height: 5),
          // 신호 LED + 채널 이름
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _levels[idx] > 0.02 ? const Color(0xFF34C759) : const Color(0xFF2A2F36),
                  ),
                ),
                Flexible(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          // 입력 게인 (채널 위쪽)
          _gainRow(idx),
          // 레벨 dB 박스
          _dbBox(faderDb(_faders[idx])),
          // 페이더존: 눈금 | 페이더 | 미터
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _scale(),
                  Expanded(child: Center(child: _verticalFader(_faders[idx], (v) => _setFader(idx, v)))),
                  const SizedBox(width: 3),
                  _meterBar(_levels[idx], _peaks[idx], _clipHold[idx] > 0),
                ],
              ),
            ),
          ),
          // PK 박스
          _pkBox('PK', _peaks[idx], _clipHold[idx] > 0),
          const SizedBox(height: 6),
          // 뮤트
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: on ? const Color(0xFF2C333D) : const Color(0xFFD13A30),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onPressed: () => _toggleMute(idx),
                child: Text(on ? 'ON' : 'MUTE', style: const TextStyle(fontSize: 11)),
              ),
            ),
          ),
          // 팬 (뮤트 밑)
          SizedBox(
            height: 20,
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: _panSlider(idx)),
          ),
          Text(panLabel(_pans[idx]), style: const TextStyle(fontSize: 9, color: Color(0xFF8A94A0))),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _mainStrip() {
    return Container(
      width: 96,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF222932),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2C3540)),
      ),
      child: Column(
        children: [
          Container(
            height: 6,
            margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            decoration: BoxDecoration(color: const Color(0xFFFFCA28), borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(height: 5),
          const Text('MAIN', style: TextStyle(fontWeight: FontWeight.w800, color: Color(0xFFFFCA28), fontSize: 13, letterSpacing: 1)),
          // 게인 자리 비움(채널과 높이 정렬)
          const SizedBox(height: 33),
          _dbBox(faderDb(_mainFader)),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _scale(),
                  Expanded(child: Center(child: _verticalFader(_mainFader, _setMain))),
                  const SizedBox(width: 3),
                  _meterBar(_mainL, _mainPkL, _mainClip > 0),
                  const SizedBox(width: 2),
                  _meterBar(_mainR, _mainPkR, _mainClip > 0),
                ],
              ),
            ),
          ),
          _pkBox('L/R', math.max(_mainPkL, _mainPkR), _mainClip > 0),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _mainOn ? const Color(0xFF2C333D) : const Color(0xFFD13A30),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
                onPressed: _toggleMainMute,
                child: Text(_mainOn ? 'ON' : 'MUTE', style: const TextStyle(fontSize: 11)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text('ST', style: TextStyle(fontSize: 9, color: Color(0xFF8A94A0))),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
