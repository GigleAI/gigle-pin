<p align="center"><img src="docs/icon.png" width="112" alt="Gigle Pin"></p>
<h1 align="center">Gigle Pin</h1>

<p align="center"><strong>Ausschneiden. Anheften. Aufnehmen.</strong><br>
Ein natives macOS-Werkzeug für Screenshots, angeheftete Bilder und Bildschirmaufnahmen —<br>
und das erste, das eine KI bedienen kann, ohne deine Maus anzufassen.</p>

<p align="center">
  <a href="https://gigle.ai/pin/"><b>Website</b></a> ·
  <a href="https://gigle.ai/pin/#download"><b>Für Mac laden</b></a> ·
  <a href="https://gigle.ai/pin/skill/">Agent-Anleitung</a>
</p>

<p align="center"><sub>
  <a href="README.md">English</a> ·
  <b>Deutsch</b> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.zh-Hans.md">简体中文</a>
</sub></p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-orange">
  <img alt="keine Abhängigkeiten" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="https://gigle.ai/pin/">
    <img src="docs/screenshots/01-capture.png" width="820" alt="Die Aufnahmeebene: abgedunkelter Bildschirm, helle Auswahl, die Werkzeugleiste zum Zeichnen">
  </a>
</p>

---

**Gigle Pin** nimmt einen Ausschnitt deines Bildschirms, heftet ihn über alle
Fenster oder nimmt ihn als Video auf — Screenshot, Anheften und Aufnahme in einer
nativen App. Swift und AppKit, null Fremdabhängigkeiten, unter 3 MB, und sie ist
da, sobald du die Taste drückst.

Das, was sonst niemand kann: **eine KI kann alles davon über `pin://` steuern,
ohne deine Maus anzufassen oder dir den Fokus zu nehmen.** Sie nimmt auf, während
du weiterarbeitest.

Das zählt jeden Monat mehr. Ein großer Teil aller Screenshots und Anleitungen
entsteht inzwischen *für* ein Modell — und immer öfter ist das Modell selbst
dasjenige, das aufnehmen sollte, um Software vorzuführen, die es gerade geändert
hat. Jedes andere Werkzeug dieser Art zwingt diesen Agenten, mit dir um den
Mauszeiger zu kämpfen.

[Snipaste](https://snipaste.com) ist hier die Messlatte, und allein sein Anheften
auf den Bildschirm ist die Installation wert. Zwei Dinge kann es nicht: Video
aufnehmen und sich von einer KI steuern lassen. Pin kann beides.

## Installieren

**Nur die App?** [Bei gigle.ai/pin herunterladen](https://gigle.ai/pin/#download) —
signiert und notarisiert, ohne Konto, nichts verlässt deinen Mac. Die App-Store-Fassung ist unterwegs.

**Etwas ändern?** Dafür liegt der Quelltext hier.

```bash
brew install xcodegen && xcodegen generate && scripts/build.sh
```

Trag vorher dein eigenes Team in `DEVELOPMENT_TEAM` in `project.yml` ein — siehe
[CONTRIBUTING.md](CONTRIBUTING.md).

## Demo

https://github.com/user-attachments/assets/b58ae0e9-13d7-4a42-98de-7acac5ec5c8d

<p align="center"><sub>Echter Einsatz, 43 Sekunden, mit Ton — der Player startet stumm.
<b>Kein Player oben?</b> GitHub liefert das Video aus seinem eigenen Anhang-Speicher, der schon einmal eines verloren hat —
sieh es dir stattdessen auf <a href="https://gigle.ai/pin/">gigle.ai/pin</a> an oder öffne
<a href="docs/media/pin-film.mp4">docs/media/pin-film.mp4</a>, den kürzeren Film, in diesem Repository.</sub></p>

## Was sie kann

| | |
| --- | --- |
| **Aufnehmen** | Alle Bildschirme einfrieren, auf Fenster oder einzelne Bedienelemente einrasten, zeichnen, Pixelfarben ablesen. |
| **Anheften** | Eine Aufnahme über alle Fenster legen — zoomen, ausblenden, hindurchklicken, alle mit einer Taste verstecken. |
| **Aufzeichnen** | Bereich als MP4 oder GIF, Systemton und Mikrofon, eine Pause, die wirklich aus der Zeitleiste verschwindet, und Halten-und-Ziehen, um mitten in der Vorführung auf den Bildschirm zu zeichnen (`⌥` als Vorgabe, oder `⌃⌥` / `⌘⌥` / `⌃⌘` / `fn`). |
| **Ansehen** | Bleibt auf dem letzten Bild stehen. Spulen, verlangsamen, Notizen auf die Zeitleiste setzen — sie werden in den Export gerendert. |

| Taste | |
| --- | --- |
| `F1` | Bereich aufnehmen |
| `F1` zweimal | Stattdessen aufzeichnen |
| `⇧F1` | Zwischenablage anheften |
| `⌘⇧F1` | Alle Angehefteten aus- / einblenden |

Alle frei belegbar. `F1` ist mit Absicht die Taste von Snipaste — macOS meldet den
Konflikt nie (`RegisterEventHotKey` gibt so oder so `noErr` zurück), deshalb bittet
dich der erste Start, sie einmal zu drücken, und sagt dir, ob Pin sie bekommen hat.

## Für KI-Agenten

Ein Agent bittet Pin, einen Bereich aufzuzeichnen, meldet seine eigenen Klicks,
damit sie im Video als Wellen erscheinen, und zeichnet auf das Ergebnis:

```bash
open -g "pin://record?x=0&y=0&w=1440&h=900&seconds=20&out=/tmp/demo.mp4"
open -g "pin://ripple?x=700&y=420"          # hier habe ich geklickt
open -g "pin://ink?x1=.2&y1=.3&x2=.5&y2=.6&tool=arrow"
```

Die Klicks eines Agenten gehen direkt an einen Prozess und erreichen nie den
System-Ereignisstrom, Pin kann sie also nicht sehen — darum meldet der Agent sie
selbst.

[`.agents/skills/pin-screen-recorder/SKILL.md`](.agents/skills/pin-screen-recorder/SKILL.md)
ist die eine Datei, die Claude Code und Codex beide lesen. Sie steckt im
App-Bundle, damit ein Agent, der Pin auf der Festplatte findet, sie offline lesen
kann — und sie liegt unter
[gigle.ai/pin/skill](https://gigle.ai/pin/skill/) für einen, der das nicht kann.

Pin schreibt von sich aus nie in deine Agent-Verzeichnisse. Unter Einstellungen ▸ KI
gibt es dafür eine Schaltfläche, und sie entfernt nur, was sie selbst abgelegt hat.

## Dokumentation

- **[docs/lessons.md](docs/lessons.md)** — was wir zuerst falsch hatten und
  welche Messung es jeweils entschieden hat. Unscharfe Aufnahmen lagen an einem
  Farbraum-Flag, nicht an der Bitrate; ein stehender Bildschirm liefert überhaupt
  keine Einzelbilder; vier unserer Tests waren grün gegen nachweislich kaputten
  Code. Lies das, bevor du etwas änderst.
- **[AGENTS.md](AGENTS.md)** — die Regeln, die diesen Code zusammenhalten.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — bauen, prüfen, Änderung einschicken.
- **[SECURITY.md](SECURITY.md)** — wie man eine Schwachstelle vertraulich meldet
  und wovor `pin://` schützt und wovor nicht.

## Lizenz

Der Code steht unter MIT — nimm ihn, ändere ihn, veröffentliche ihn.

Der Name *Gigle Pin*, das Vogel-Zeichen, das Symbol und der Film in dieser
README sind Marken von Gigle.AI und **nicht** von dieser Lizenz gedeckt. Forke
frei; gib deinem Fork einen eigenen Namen und ein eigenes Symbol, damit ihn
niemand in dem Glauben lädt, er käme von uns.

Gebaut von [Gigle.AI](https://gigle.ai).
