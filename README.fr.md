<p align="center"><img src="docs/icon.png" width="112" alt="Gigle Pin"></p>
<h1 align="center">Gigle Pin</h1>

<p align="center"><strong>Capturer. Épingler. Enregistrer.</strong><br>
Un outil macOS natif de capture d’écran, d’épinglage et d’enregistrement —<br>
et le premier qu’une IA peut piloter sans toucher à votre souris.</p>

<p align="center">
  <a href="https://gigle.ai/pin/"><b>Site</b></a> ·
  <a href="https://gigle.ai/pin/#download"><b>Télécharger pour Mac</b></a> ·
  <a href="https://gigle.ai/pin/skill/">Notice pour agents</a>
</p>

<p align="center"><sub>
  <a href="README.md">English</a> ·
  <a href="README.de.md">Deutsch</a> ·
  <a href="README.es.md">Español</a> ·
  <b>Français</b> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.zh-Hans.md">简体中文</a>
</sub></p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-orange">
  <img alt="aucune dépendance" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="https://gigle.ai/pin/">
    <img src="docs/screenshots/01-capture.png" width="820" alt="Le calque de capture : écran assombri, sélection éclairée, barre d’annotation">
  </a>
</p>

---

**Gigle Pin** prend une zone de votre écran, l’épingle au-dessus de toutes les
fenêtres, ou l’enregistre : capture, épinglage et vidéo dans une seule app
native. Swift et AppKit, zéro dépendance externe, moins de 3 Mo, et elle s’ouvre
à l’instant où vous appuyez sur la touche.

Ce que rien d’autre ne fait : **une IA peut tout piloter via `pin://` sans
toucher à votre souris ni vous prendre le focus.** Elle enregistre pendant que
vous continuez à travailler.

Cela compte un peu plus chaque mois. Une grande part des captures et des
tutoriels sont désormais faits *pour* qu’un modèle les lise — et de plus en plus,
celui qui devrait enregistrer **est** le modèle, en train de montrer un logiciel
qu’il vient de modifier. Tous les autres outils de cette catégorie obligent cet
agent à vous disputer le curseur.

[Snipaste](https://snipaste.com) est la référence à battre, et son épinglage à
l’écran justifie à lui seul l’installation. Deux choses qu’il ne sait pas faire :
enregistrer une vidéo, et se laisser piloter par une IA. Pin fait les deux.

## Installer

**Vous voulez juste l’app ?** [Téléchargez-la sur gigle.ai/pin](https://gigle.ai/pin/#download) —
signée et notariée, sans compte, et rien ne quitte votre Mac. La version App Store arrive.

**Vous voulez la modifier ?** C’est pour cela que le code est ici.

```bash
brew install xcodegen && xcodegen generate && scripts/build.sh
```

Mettez d’abord votre propre équipe dans `DEVELOPMENT_TEAM`, dans `project.yml` —
voir [CONTRIBUTING.md](CONTRIBUTING.md).

## Démo

https://github.com/user-attachments/assets/b58ae0e9-13d7-4a42-98de-7acac5ec5c8d

<p align="center"><sub>Usage réel, 43 secondes, avec le son — le lecteur démarre en sourdine.
<b>Pas de lecteur ci-dessus ?</b> GitHub sert cette vidéo depuis son propre stockage de pièces jointes, qui en a déjà perdu une —
regardez-la sur <a href="https://gigle.ai/pin/">gigle.ai/pin</a>, ou ouvrez
<a href="docs/media/pin-film.mp4">docs/media/pin-film.mp4</a>, le même film, dans ce dépôt.</sub></p>

## Ce qu’elle fait

| | |
| --- | --- |
| **Capturer** | Fige tous les écrans, s’accroche aux fenêtres ou à un seul contrôle, annote, lit la couleur d’un pixel. |
| **Épingler** | Pose une capture au-dessus de toutes les fenêtres : zoom, fondu, clic au travers, tout masquer d’une touche. |
| **Enregistrer** | Une zone en MP4 ou GIF, son de l’ordinateur et micro, une pause réellement retirée de la timeline, et maintenir-glisser pour dessiner à l’écran en pleine démo (`⌥` par défaut, ou `⌃⌥` / `⌘⌥` / `⌃⌘` / `fn`). |
| **Revoir** | S’arrête sur la dernière image. Naviguez, ralentissez, placez des annotations sur la timeline : elles sont gravées à l’export. |

| Touche | |
| --- | --- |
| `F1` | Capturer une zone |
| `F1` deux fois | Enregistrer à la place |
| `⇧F1` | Épingler le presse-papiers |
| `⌘⇧F1` | Masquer / afficher toutes les épingles |

Toutes réassignables. `F1` est la touche de Snipaste, volontairement : macOS ne
signale jamais le conflit (`RegisterEventHotKey` renvoie `noErr` dans les deux
cas), donc au premier lancement Pin vous demande de l’appuyer une fois et vous
dit s’il l’a obtenue.

## Pour les agents IA

Un agent demande à Pin d’enregistrer une zone, signale ses propres clics pour
qu’ils apparaissent en ondes dans la vidéo, et dessine sur le résultat :

```bash
open -g "pin://record?x=0&y=0&w=1440&h=900&seconds=20&out=/tmp/demo.mp4"
open -g "pin://ripple?x=700&y=420"          # j’ai cliqué ici
open -g "pin://ink?x1=.2&y1=.3&x2=.5&y2=.6&tool=arrow"
```

Les clics d’un agent sont envoyés directement à un processus et n’entrent jamais
dans le flux d’événements du système : Pin ne peut donc pas les voir, et c’est
pourquoi l’agent les signale lui-même.

[`.agents/skills/pin-screen-recorder/SKILL.md`](.agents/skills/pin-screen-recorder/SKILL.md)
est le seul fichier que lisent à la fois Claude Code et Codex. Il est embarqué
dans l’app, pour qu’un agent qui trouve Pin sur le disque puisse le lire hors
ligne — et il est publié sur
[gigle.ai/pin/skill](https://gigle.ai/pin/skill/) pour celui qui ne le peut pas.

Pin n’écrit jamais de lui-même dans vos dossiers d’agents. Réglages ▸ IA a un
bouton pour cela, et il ne retire que ce qu’il y a mis.

## Documentation

- **[docs/lessons.md](docs/lessons.md)** — ce que nous avions d’abord faux, et la
  mesure qui a tranché à chaque fois. Les enregistrements flous venaient d’un
  indicateur de plage de couleurs, pas du débit ; un écran immobile ne produit
  aucune image ; quatre de nos tests passaient sur du code prouvé cassé. À lire
  avant de changer quoi que ce soit.
- **[AGENTS.md](AGENTS.md)** — les règles qui gardent ce code cohérent.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — compiler, vérifier, envoyer un changement.
- **[SECURITY.md](SECURITY.md)** — comment signaler une faille en privé, et ce que
  `pin://` protège ou ne protège pas.

## Licence

Le code est sous MIT : prenez-le, modifiez-le, publiez-le.

Le nom *Gigle Pin*, la marque à l’oiseau, l’icône et le film de ce README sont
des marques de Gigle.AI et ne sont **pas** couverts par cette licence. Forkez
librement ; donnez à votre fork son propre nom et sa propre icône, pour que
personne ne le télécharge en croyant qu’il vient de nous.

Construit par [Gigle.AI](https://gigle.ai).
