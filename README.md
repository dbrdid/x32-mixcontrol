# X32 MixControl (비공식 · Android)

> ⚠️ **비공식 앱입니다.** Music Tribe / Behringer 와 무관하며, "X32 / M32"는 호환 대상 모델 표기일 뿐입니다.

Behringer **X32 / M32** 디지털 콘솔을 **갤럭시탭 등 안드로이드**에서 무료로 제어하는 비공식 앱.
공식 무료 앱은 데스크탑(X32-Edit)·아이패드(X32-Mix)만 있고, 안드로이드는 유료(Mixing Station)뿐이라 직접 만든 버전.

- **표시 이름:** X32 MixControl
- **패키지명(영구):** `ai.byeori.mixcontrol`

## 동작 원리
X32는 **OSC** 메시지를 **UDP 포트 10023** 으로 주고받아 제어한다. 앱이 같은 와이파이망에서 콘솔 IP로 직접 통신.
- 채널 페이더 `/ch/NN/mix/fader` (float 0~1)
- 채널 뮤트 `/ch/NN/mix/on` (int 1=ON, 0=뮤트)
- 채널 팬 `/ch/NN/mix/pan` (float 0~1, 0.5=중앙)
- 채널 이름 `/ch/NN/config/name` (string), 색상 `/ch/NN/config/color` (int 0~15)
- 메인 페이더 `/main/st/mix/fader` (float 0~1), 메인 뮤트 `/main/st/mix/on` (int)
- **DCA 그룹** `/dca/N/fader` (float)·`/dca/N/on` (int)·`/dca/N/config/name|color` — N=1~8, 패딩·`/mix` 없는 그룹 마스터
- `/xremote` 주기 전송 → 콘솔의 변경값 수신, 연결 시 현재값 동기화

> ⚠️ **데이터 흐름은 무조건 믹서(콘솔) → 앱.** 연결 시 query만, 사용자가 직접 조작할 때만 send. 앱이 콘솔을 멋대로 덮어쓰지 않는다.

## 기능
**v0.1 (MVP)**
- 콘솔 IP 입력 → 연결/끊기
- 채널 1~32 페이더 + ON/MUTE
- 메인 페이더
- 연결 시 콘솔 현재 상태로 슬라이더 동기화

**v0.2 (추가)**
- 채널 **이름** 표시(콘솔에서 읽어옴, 없으면 CH NN)
- 채널 **색상 띠**(콘솔 색상 코드 반영)
- 페이더 **dB 실시간 표시**(표준 4구간 변환, 0.75→0dB)
- 채널 **팬**(좌우, L/C/R 라벨)
- **메인 뮤트**(ON/MUTE)

**v0.3 (추가)**
- 채널별 **레벨 미터** — `/meters` 로 `/meters/1` 뱅크 구독, blob 디코딩(`[count int32 LE][float32 LE×96]`, [0..31]=입력 채널), dBFS 색상(초록/노랑/빨강)
- **피크 홀드**(흰 선, 0.90 감쇠) + **클립 표시**(0dBFS 이상 빨간 래치 1.5초) — 콘솔이 안 주므로 클라이언트 계산
- 채널 이름 옆 **신호 LED**(소리 들어오면 초록)

**v0.4 (추가)**
- **입력 게인**(프리앰프) — `/headamp/NNN/gain` (−12~+60dB), 채널 1~32 → headamp 0~31. 채널 위쪽 슬라이더
- **메인 L/R 미터** — `/meters/5` 의 [24]=L, [25]=R (입력 `/meters/1`과 float 개수로 구분)
- 미터 **컬러 그라데이션** + 페이더 **dB 눈금자** + **PK(dBFS) 박스**
- 입력 미터는 **뮤트와 무관**(신호 흐름상 게인 다음·페이더/뮤트 앞), 게인엔 반응
- **팬을 뮤트 아래로** 재배치

**v0.5 (UI 전면 개편)**
- **8채널 레이어 뱅크** — 좌측 세로 레이어바로 `CH 1–8/9–16/17–24/25–32 · AUX · FX · BUS 1–8/9–16` 전환(한 번에 8채널 + 큰 페이더)
- **통합 페이더+미터 바**(CustomPainter) + **위·아래 드래그 전용**(탭 점프 없음) + dB 눈금 가로선
- **세로 게인** · **삼각형 팬**(중앙 스냅)
- **채널 상세**(이름 탭): 4밴드 PEQ 곡선 **드래그 + RTA** · 게이트/컴프 · 게인
- **AUX In(PC 등)** 조절 지원 · **가로 모드 고정** · 연결 전 **배너** 영역

**v0.6 (추가)**
- **그룹 DCA 1~8** — 레이어바 맨 끝 `DCA 1–8`. 각 DCA = 페이더·뮤트·이름·색상 미러링/조작(그룹 마스터라 pan/게인/EQ/미터 없음)
- **게인 세로로 확대 + 감도 완화** — 태블릿에서 위아래 조절이 쉽게(위젯 높이의 2배를 끌어야 풀레인지 = 정밀)

> 다음 후보: 버스 보내기(send), 씬 저장, DCA 멤버십(채널↔DCA 배정) 표시.

## 빌드 (클라우드 자동)
로컬에 개발도구 설치 불필요. GitHub에 올리면 **Actions가 APK를 자동 빌드**한다.
- 워크플로: `.github/workflows/build-apk.yml`
- 결과물: Actions 실행 → Artifacts의 `x32control-apk` (`app-release.apk`)
- 골격은 CI에서 `flutter create` 로 생성하고 `app_lib/main.dart`·`app_pubspec.yaml` 을 덮어써 빌드.

## 설치 (갤럭시탭)
1. Actions에서 `app-release.apk` 다운로드 → 탭으로 전송
2. 탭: 설정 → 보안 → "출처를 알 수 없는 앱 설치" 허용
3. APK 탭해서 설치 → 앱 실행 → 콘솔 IP 입력 → 연결

## 구조
```
app_lib/main.dart            앱 본체(OSC + 믹서 UI)
app_pubspec.yaml             패키지 설정
.github/workflows/build-apk.yml  클라우드 빌드
```
