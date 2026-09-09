<p align="center"><img src="docs/icon.png" width="112" alt="Gigle Pin"></p>
<h1 align="center">Gigle Pin</h1>

<p align="center"><strong>잘라내고. 붙여두고. 녹화하고.</strong><br>
macOS 네이티브 스크린샷 · 화면 고정 · 화면 녹화 도구,<br>
그리고 마우스를 건드리지 않고 AI가 조작할 수 있는 첫 번째 도구.</p>

<p align="center">
  <a href="https://gigle.ai/pin/"><b>웹사이트</b></a> ·
  <a href="https://gigle.ai/pin/#download"><b>Mac용 다운로드</b></a> ·
  <a href="https://gigle.ai/pin/skill/">에이전트 설명서</a>
</p>

<p align="center"><sub>
  <a href="README.md">English</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ja.md">日本語</a> ·
  <b>한국어</b> ·
  <a href="README.zh-Hans.md">简体中文</a>
</sub></p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-orange">
  <img alt="의존성 없음" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="https://gigle.ai/pin/">
    <img src="docs/screenshots/01-capture.png" width="820" alt="캡처 화면: 어두워진 바탕, 밝은 선택 영역, 주석 도구 막대">
  </a>
</p>

---

**Gigle Pin**은 화면의 한 영역을 잘라내고, 모든 창 위에 고정하고, 또는 녹화합니다.
캡처와 고정과 영상이 하나의 네이티브 앱에 들어 있습니다. Swift와 AppKit만 쓰고,
서드파티 의존성은 0, 3 MB 미만이며, 키를 누르는 순간 열립니다.

다른 어떤 도구도 하지 않는 것: **AI가 `pin://`로 이 모든 것을 조작할 수 있습니다.
당신의 마우스도, 포커스도 빼앗지 않고요.** 당신이 계속 일하는 동안 녹화합니다.

이 점은 달이 갈수록 중요해집니다. 스크린샷과 사용 설명의 상당수가 이미 *모델이 읽기
위해* 찍히고 있고, 점점 더 녹화해야 할 당사자가 **모델 자신**입니다. 방금 자기가 고친
소프트웨어를 시연하는 것이죠. 이 분야의 다른 도구들은 그 에이전트가 당신과 커서를
두고 싸우게 만듭니다.

[Snipaste](https://snipaste.com)가 넘어야 할 기준이고, 화면 고정 하나만으로도 설치할
가치가 있습니다. 다만 두 가지를 못 합니다. 영상 녹화, 그리고 AI에 의한 조작. Pin은
둘 다 합니다.

## 설치

**앱만 필요하다면**: [gigle.ai/pin에서 내려받기](https://gigle.ai/pin/#download) —
서명과 공증이 되어 있고, 계정이 필요 없으며, 아무것도 Mac 밖으로 나가지 않습니다. App Store 버전은 준비 중입니다.

**고치고 싶다면**: 그래서 소스가 여기 있습니다.

```bash
brew install xcodegen && xcodegen generate && scripts/build.sh
```

먼저 `project.yml`의 `DEVELOPMENT_TEAM`을 본인 팀으로 바꾸세요 —
[CONTRIBUTING.md](CONTRIBUTING.md) 참고.

## 데모

https://github.com/user-attachments/assets/b58ae0e9-13d7-4a42-98de-7acac5ec5c8d

<p align="center"><sub>실제 사용, 43초, 소리 있음 — 플레이어는 음소거로 시작합니다.
<b>위에 플레이어가 안 보이나요?</b> 이 영상은 GitHub 자체 첨부 저장소에서 제공되는데, 전에 한 번 사라진 적이 있습니다.
<a href="https://gigle.ai/pin/">gigle.ai/pin</a>에서 보거나, 이 저장소에 있는 더 짧은 영상
<a href="docs/media/pin-film.mp4">docs/media/pin-film.mp4</a>를 열어 보세요.</sub></p>

## 무엇을 하나

| | |
| --- | --- |
| **캡처** | 모든 디스플레이를 멈춰 세우고, 창이나 창 안의 버튼 하나에 맞춰 잡고, 주석을 그리고, 픽셀 색을 읽습니다. |
| **고정** | 찍은 것을 모든 창 위에 올려 둡니다. 확대, 반투명, 클릭 통과, 한 키로 전부 숨기기. |
| **녹화** | 영역을 MP4나 GIF로, 컴퓨터 소리와 마이크, **타임라인에서 실제로 잘려 나가는** 일시정지, 그리고 시연 도중 화면에 그리기 위한 누른 채 드래그(기본 `⌥`, `⌃⌥` / `⌘⌥` / `⌃⌘` / `fn`으로 변경 가능). |
| **검토** | 마지막 프레임에서 멈춥니다. 탐색하고, 느리게 돌리고, 타임라인에 주석을 놓으면 내보낼 때 함께 구워집니다. |

| 키 | |
| --- | --- |
| `F1` | 영역 캡처 |
| `F1` 두 번 | 대신 녹화 |
| `⇧F1` | 클립보드를 화면에 고정 |
| `⌘⇧F1` | 고정한 것 전부 숨기기 / 보이기 |

전부 다시 지정할 수 있습니다. `F1`이 Snipaste의 키인 것은 의도한 것입니다. macOS는
충돌을 알려 주지 않습니다(`RegisterEventHotKey`는 어느 쪽이든 `noErr`를 돌려줍니다).
그래서 처음 실행할 때 한 번 눌러 보게 하고, Pin이 그 키를 가져갔는지 알려 줍니다.

## AI 에이전트를 위해

에이전트는 Pin에게 영역 녹화를 요청하고, 자기가 클릭한 위치를 알려 영상에 물결로
나타나게 하고, 결과 위에 그립니다:

```bash
open -g "pin://record?x=0&y=0&w=1440&h=900&seconds=20&out=/tmp/demo.mp4"
open -g "pin://ripple?x=700&y=420"          # 여기를 클릭했습니다
open -g "pin://ink?x1=.2&y1=.3&x2=.5&y2=.6&tool=arrow"
```

에이전트의 클릭은 프로세스로 곧장 전달되고 시스템 이벤트 흐름에는 들어가지 않습니다.
그래서 Pin이 볼 수 없고, 에이전트가 직접 알려 주는 것입니다.

[`.agents/skills/pin-screen-recorder/SKILL.md`](.agents/skills/pin-screen-recorder/SKILL.md)
가 Claude Code와 Codex가 함께 읽는 단 하나의 파일입니다. 앱 번들 안에도 들어 있어서
디스크에서 Pin을 찾은 에이전트는 오프라인으로도 읽을 수 있고, 그러지 못하는 쪽을 위해
[gigle.ai/pin/skill](https://gigle.ai/pin/skill/)에서도 제공합니다.

Pin은 스스로 여러분의 에이전트 디렉터리에 쓰지 않습니다. 설정 ▸ AI에 그 버튼이 있고,
자기가 넣은 것만 지웁니다.

## 문서

- **[docs/lessons.md](docs/lessons.md)** — 우리가 처음에 틀렸던 것들과, 각각을
  결론지은 실측. 녹화가 뿌옇던 원인은 비트레이트가 아니라 색 범위 플래그였고,
  정지된 화면은 프레임을 한 장도 내놓지 않으며, 우리 테스트 넷은 고장 났다고
  증명된 코드에서 통과했습니다. 무엇이든 바꾸기 전에 읽어 보세요.
- **[AGENTS.md](AGENTS.md)** — 이 코드베이스를 일관되게 지켜 주는 규칙들.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — 빌드하고, 검증하고, 변경을 보내는 법.
- **[SECURITY.md](SECURITY.md)** — 취약점을 비공개로 알리는 방법, 그리고 `pin://`가
  무엇을 막고 무엇을 막지 않는지.

## 라이선스

코드는 MIT입니다. 가져가고, 고치고, 배포하세요.

*Gigle Pin*이라는 이름, 새 마크, 아이콘, 이 README의 영상은 Gigle.AI의 상표이며 그
라이선스에 **포함되지 않습니다**. 자유롭게 포크하되, 포크에는 고유한 이름과 아이콘을
붙여 주세요. 누군가 그것을 우리가 만든 것으로 알고 내려받는 일이 없도록요.

[Gigle.AI](https://gigle.ai)가 만들었습니다.
