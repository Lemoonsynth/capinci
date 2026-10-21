# capcut2davinci.py (legacy, frozen)

> Superseded by the Capinci app; kept for reference. Original notes in French below.

Convertit un projet CapCut (desktop, Mac) en timeline FCPXML importable dans DaVinci Resolve.
Python 3 seul, aucune dépendance.

```bash
python3 capcut2davinci.py --list                         # liste tes projets CapCut
python3 capcut2davinci.py "My Project" -o "out/My Project.fcpxml"
```

Dans Resolve : **File → Import → Timeline…** puis choisis le `.fcpxml`.

## Ce qui passe
- Coupes, toutes les pistes vidéo/audio (superpositions comprises)
- Clips composés (compound clips), imbriqués
- Vitesses constantes et **courbes de vitesse** (voir ci-dessous)
- Échelle, position, rotation, miroir, opacité
- Volume et fondus audio
- Textes (contenu seulement, style par défaut)
- Marqueurs du projet

## Ce qui ne passe pas (signalé en marqueurs + listé à la fin de la conversion)
Effets, filtres, réglages couleur, transitions, animations d'entrée/sortie, masques, keyframes.

## Courbes de vitesse
CapCut répartit les points de la courbe sur la durée du média source. Le convertisseur
reproduit la forme de la courbe (interpolation linéaire entre les points) puis la recale
pour que le clip commence et finisse exactement sur les mêmes images que dans CapCut.
CapCut lisse ses courbes d'une façon non documentée : à l'intérieur du clip, la rampe peut
différer légèrement (quelques %) de l'original.

Dans Resolve, chaque courbe devient une vitesse variable (Retime Controls) : un segment
par palier plat, et 6 segments par rampe.

## Projets HDR
Si le projet CapCut est en HDR (PQ / ST 2084), la timeline est marquée `Rec. 2020 PQ` et le
timecode suit le réglage drop-frame de CapCut. Resolve ne règle **pas** la gestion des
couleurs tout seul : avant d'importer, dans Project Settings →
- Master Settings : 1920×1080, 59,94 i/s, cocher « Use drop frame timecode » ;
- Color Management : Color science « DaVinci YRGB Color Managed », Color processing mode
  « HDR », Output color space « Rec.2100 ST2084 ».
À l'import, coche « Use color information ».

## Dans Resolve
- Les pistes masquées dans CapCut arrivent en clips désactivés (icône rouge barrée) :
  réactive-les avec Clip → Enable/Disable Clip si besoin.
- La piste V1 reste vide : c'est le support de la timeline FCPXML, tes pistes CapCut
  commencent en V2.
- Les clips composés s'ouvrent avec Clip → Open in Timeline.

## Limites connues
- Les projets CapCut chiffrés (certaines versions récentes) ne sont pas lisibles.
- Les médias du cache CapCut (stickers, éléments en ligne) apparaissent hors ligne s'ils ont été supprimés.
