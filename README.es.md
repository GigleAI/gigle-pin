<p align="center"><img src="docs/icon.png" width="112" alt="Gigle Pin"></p>
<h1 align="center">Gigle Pin</h1>

<p align="center"><strong>Recorta. Fija. Graba.</strong><br>
Una herramienta nativa de macOS para capturas, imágenes fijadas y grabación de pantalla —<br>
y la primera que una IA puede manejar sin tocarte el ratón.</p>

<p align="center">
  <a href="https://gigle.ai/pin/"><b>Sitio web</b></a> ·
  <a href="https://gigle.ai/pin/#download"><b>Descargar para Mac</b></a> ·
  <a href="https://gigle.ai/pin/skill/">Instrucciones para agentes</a>
</p>

<p align="center"><sub>
  <a href="README.md">English</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <b>Español</b> ·
  <a href="README.fr.md">Français</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.zh-Hans.md">简体中文</a>
</sub></p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-orange">
  <img alt="sin dependencias" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="https://gigle.ai/pin/">
    <img src="docs/screenshots/01-capture.png" width="820" alt="La capa de captura: pantalla atenuada, selección iluminada y la barra de anotación">
  </a>
</p>

---

**Gigle Pin** toma una zona de tu pantalla, la fija por encima de todas las
ventanas o la graba: captura, fijado y vídeo en una sola app nativa. Swift y
AppKit, cero dependencias de terceros, menos de 3 MB, y aparece en el momento en
que pulsas la tecla.

Lo que no hace ninguna otra: **una IA puede manejarlo todo a través de `pin://`
sin tocar tu ratón ni quitarte el foco.** Graba mientras tú sigues trabajando.

Esto importa más cada mes. Buena parte de las capturas y los tutoriales se hacen
ya *para* que los lea un modelo, y cada vez más el que debería estar grabando
**es** el modelo, enseñando un software que acaba de cambiar. Cualquier otra
herramienta de esta categoría obliga a ese agente a pelearse contigo por el cursor.

[Snipaste](https://snipaste.com) es la referencia a batir, y solo por fijar
imágenes en pantalla ya merece la instalación. Dos cosas que no puede hacer:
grabar vídeo y dejarse manejar por una IA. Pin hace las dos.

## Instalar

**¿Solo quieres la app?** [Descárgala en gigle.ai/pin](https://gigle.ai/pin/#download) —
firmada y notarizada, sin cuenta, y nada sale de tu Mac. La versión de la App Store está en camino.

**¿Quieres cambiarla?** Para eso está aquí el código.

```bash
brew install xcodegen && xcodegen generate && scripts/build.sh
```

Antes pon tu propio equipo en `DEVELOPMENT_TEAM`, dentro de `project.yml` — mira
[CONTRIBUTING.md](CONTRIBUTING.md).

## Demostración

https://github.com/user-attachments/assets/b58ae0e9-13d7-4a42-98de-7acac5ec5c8d

<p align="center"><sub>Uso real, 43 segundos, con sonido: el reproductor empieza silenciado.
<b>¿No ves el reproductor?</b> GitHub sirve ese vídeo desde su propio almacén de adjuntos, que ya perdió uno —
míralo en <a href="https://gigle.ai/pin/">gigle.ai/pin</a> o abre
<a href="docs/media/pin-film.mp4">docs/media/pin-film.mp4</a>, la misma película, en este repositorio.</sub></p>

## Qué hace

| | |
| --- | --- |
| **Capturar** | Congela todas las pantallas, se ajusta a ventanas o a un solo control, anota y lee el color de un píxel. |
| **Fijar** | Deja una captura por encima de todas las ventanas: amplía, atenúa, haz clic a través de ella, escóndelas todas con una tecla. |
| **Grabar** | Una zona a MP4 o GIF, audio del ordenador y micrófono, una pausa que se recorta de verdad de la línea de tiempo, y mantener y arrastrar para dibujar en pantalla en mitad de la demostración (`⌥` por defecto, o `⌃⌥` / `⌘⌥` / `⌃⌘` / `fn`). |
| **Revisar** | Se detiene en el último fotograma. Desplázate, ralentiza, coloca anotaciones en la línea de tiempo: quedan grabadas en la exportación. |

| Tecla | |
| --- | --- |
| `F1` | Capturar una zona |
| `F1` dos veces | Grabar en su lugar |
| `⇧F1` | Fijar el portapapeles |
| `⌘⇧F1` | Ocultar / mostrar todo lo fijado |

Todas reasignables. `F1` es la tecla de Snipaste a propósito: macOS nunca avisa
del conflicto (`RegisterEventHotKey` devuelve `noErr` en cualquier caso), así que
el primer arranque te pide pulsarla una vez y te dice si Pin se quedó con ella.

## Para agentes de IA

Un agente le pide a Pin que grabe una zona, informa de sus propios clics para que
aparezcan como ondas en el vídeo, y dibuja sobre el resultado:

```bash
open -g "pin://record?x=0&y=0&w=1440&h=900&seconds=20&out=/tmp/demo.mp4"
open -g "pin://ripple?x=700&y=420"          # he hecho clic aquí
open -g "pin://ink?x1=.2&y1=.3&x2=.5&y2=.6&tool=arrow"
```

Los clics de un agente se envían directamente a un proceso y nunca entran en el
flujo de eventos del sistema, así que Pin no puede verlos; por eso los informa el
propio agente.

[`.agents/skills/pin-screen-recorder/SKILL.md`](.agents/skills/pin-screen-recorder/SKILL.md)
es el único archivo que leen tanto Claude Code como Codex. Viaja dentro del
paquete de la app, de modo que un agente que encuentre Pin en el disco pueda
leerlo sin conexión, y se publica en
[gigle.ai/pin/skill](https://gigle.ai/pin/skill/) para el que no pueda.

Pin nunca escribe por su cuenta en tus carpetas de agentes. Ajustes ▸ IA tiene un
botón para eso, y solo retira lo que él mismo dejó.

## Documentación

- **[docs/lessons.md](docs/lessons.md)** — en qué nos equivocamos primero y qué
  medición resolvió cada caso. Las grabaciones borrosas eran una marca de rango
  de color, no el bitrate; una pantalla quieta no produce ni un fotograma;
  cuatro de nuestras pruebas pasaban sobre código demostrablemente roto. Lee esto
  antes de cambiar nada.
- **[AGENTS.md](AGENTS.md)** — las reglas que mantienen coherente este código.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — compilar, verificar, enviar un cambio.
- **[SECURITY.md](SECURITY.md)** — cómo informar de una vulnerabilidad en privado,
  y de qué protege y de qué no protege `pin://`.

## Licencia

El código es MIT: cógelo, cámbialo, publícalo.

El nombre *Gigle Pin*, la marca del pájaro, el icono y la película de este README
son marcas de Gigle.AI y **no** están cubiertos por esa licencia. Bifurca sin
problema; dale a tu bifurcación su propio nombre e icono para que nadie la
descargue creyendo que viene de nosotros.

Hecho por [Gigle.AI](https://gigle.ai).
