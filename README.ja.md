<p align="center"><img src="docs/icon.png" width="112" alt="Gigle Pin"></p>
<h1 align="center">Gigle Pin</h1>

<p align="center"><strong>切り取る。貼り付ける。録画する。</strong><br>
macOS ネイティブのスクリーンショット・画面貼り付け・画面録画ツール。<br>
そして、あなたのマウスに触れずに AI が操作できる最初の一本。</p>

<p align="center">
  <a href="https://gigle.ai/pin/"><b>ウェブサイト</b></a> ·
  <a href="https://gigle.ai/pin/#download"><b>Mac 版をダウンロード</b></a> ·
  <a href="https://gigle.ai/pin/skill/">エージェント向け説明書</a>
</p>

<p align="center"><sub>
  <a href="README.md">English</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.fr.md">Français</a> ·
  <b>日本語</b> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.zh-Hans.md">简体中文</a>
</sub></p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-orange">
  <img alt="依存ライブラリなし" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="https://gigle.ai/pin/">
    <img src="docs/screenshots/01-capture.png" width="820" alt="キャプチャ画面：暗くなった画面、明るい選択範囲、注釈ツールバー">
  </a>
</p>

---

**Gigle Pin** は画面の一部を切り取り、すべてのウィンドウの上に貼り付け、あるいは
録画します。キャプチャ・貼り付け・動画がひとつのネイティブアプリに入っています。
Swift と AppKit のみ、サードパーティ依存はゼロ、3 MB 未満。キーを押した瞬間に開きます。

ほかにない一点：**AI が `pin://` 経由ですべてを操作できます。あなたのマウスにも
フォーカスにも触れずに。** あなたが作業を続けている間に録画します。

これは月を追うごとに重みを増しています。スクリーンショットや操作説明の多くは、
すでに**モデルに読ませるため**に撮られていて、しかも録画するべき当人がモデル自身
——自分が今書き換えたソフトを実演する——という場面が増えています。この分野のほかの
ツールは、そのエージェントにカーソルの取り合いを強います。

[Snipaste](https://snipaste.com) が超えるべき相手で、画面への貼り付けだけでも
入れる価値があります。できないことが二つ：動画の録画と、AI からの操作。Pin は
どちらもできます。

## インストール

**アプリだけ欲しい場合**：[gigle.ai/pin からダウンロード](https://gigle.ai/pin/#download)。
署名と公証済み、アカウント不要、何ひとつあなたの Mac から出ません。App Store 版は準備中です。

**中身を変えたい場合**：そのためにソースがここにあります。

```bash
brew install xcodegen && xcodegen generate && scripts/build.sh
```

先に `project.yml` の `DEVELOPMENT_TEAM` を自分のチームに変えてください。
[CONTRIBUTING.md](CONTRIBUTING.md) を参照。

## デモ

https://github.com/user-attachments/assets/b58ae0e9-13d7-4a42-98de-7acac5ec5c8d

<p align="center"><sub>実際の使用、43 秒、音声あり（プレーヤーは消音で始まります）。
<b>上にプレーヤーが出ませんか？</b> この動画は GitHub 自身の添付ファイル置き場から配信されていて、以前に一度消えたことがあります。
その場合は <a href="https://gigle.ai/pin/">gigle.ai/pin</a> で見るか、このリポジトリにある同じ映像
<a href="docs/media/pin-film.mp4">docs/media/pin-film.mp4</a> を開いてください。</sub></p>

## できること

| | |
| --- | --- |
| **キャプチャ** | すべてのディスプレイを固定し、ウィンドウや単体のコントロールに吸着、注釈を描き、ピクセルの色を読み取ります。 |
| **貼り付け** | 撮ったものをすべてのウィンドウの上に置きます。拡大、半透明化、クリックの透過、ひとつのキーで全部を隠す。 |
| **録画** | 範囲を MP4 か GIF に、システム音声とマイク、**タイムラインから本当に削られる**一時停止、そして実演の途中で画面に描くための押しっぱなしドラッグ（既定は `⌥`、`⌃⌥` / `⌘⌥` / `⌃⌘` / `fn` にも変更可）。 |
| **確認** | 最後のフレームで止まります。シーク、スロー再生、タイムライン上への注釈——書き出し時に焼き込まれます。 |

| キー | |
| --- | --- |
| `F1` | 範囲をキャプチャ |
| `F1` を2回 | 代わりに録画 |
| `⇧F1` | クリップボードを貼り付け |
| `⌘⇧F1` | 貼り付けたものを全部隠す / 出す |

すべて変更できます。`F1` が Snipaste と同じなのは意図的です。macOS は競合を一切
知らせません（`RegisterEventHotKey` はどちらの場合も `noErr` を返します）。だから
初回起動で一度押してもらい、Pin が取れたかどうかをその場で伝えます。

## AI エージェント向け

エージェントは Pin に範囲の録画を依頼し、自分のクリックを申告して動画上に波紋として
表示させ、結果の上に描きます：

```bash
open -g "pin://record?x=0&y=0&w=1440&h=900&seconds=20&out=/tmp/demo.mp4"
open -g "pin://ripple?x=700&y=420"          # ここをクリックしました
open -g "pin://ink?x1=.2&y1=.3&x2=.5&y2=.6&tool=arrow"
```

エージェントのクリックはプロセスへ直接送られ、システムのイベント列には入りません。
Pin からは見えないので、エージェント自身が申告します。

[`.agents/skills/pin-screen-recorder/SKILL.md`](.agents/skills/pin-screen-recorder/SKILL.md)
が、Claude Code と Codex の両方が読む唯一のファイルです。アプリのバンドル内にも
入っているので、ディスク上の Pin を見つけたエージェントはオフラインでも読めます。
それができないエージェントのために
[gigle.ai/pin/skill](https://gigle.ai/pin/skill/) でも配信しています。

Pin が自分からあなたのエージェント用ディレクトリに書き込むことはありません。
設定 ▸ AI にそのためのボタンがあり、自分が置いたものだけを取り除きます。

## ドキュメント

- **[docs/lessons.md](docs/lessons.md)** — 最初に間違えたことと、それぞれを決着
  させた実測。録画がぼやけていた原因はビットレートではなく色域のフラグでした。
  静止した画面はフレームを一枚も出しません。私たちのテストのうち四つは、壊れて
  いると証明されたコードに対して緑でした。何かを変える前にこれを読んでください。
- **[AGENTS.md](AGENTS.md)** — このコードを一貫させている決まりごと。
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — ビルド、検証、変更の送り方。
- **[SECURITY.md](SECURITY.md)** — 脆弱性を非公開で報告する方法と、`pin://` が
  何を守り、何を守らないか。

## ライセンス

コードは MIT です。取って、変えて、公開してください。

*Gigle Pin* という名前、鳥のマーク、アイコン、この README の映像は Gigle.AI の
商標であり、そのライセンスの対象では**ありません**。フォークは自由です。ただし
フォークには独自の名前とアイコンを付けてください。私たちが出したものだと
思って誰かがダウンロードすることがないように。

[Gigle.AI](https://gigle.ai) が作りました。
