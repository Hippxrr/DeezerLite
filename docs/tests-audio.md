# Tests audio sur iPhone

À refaire après chaque changement touchant au son (`Core/Player.swift`, `Audio/`). Sur un vrai iPhone, app en
arrière-plan sauf mention contraire. Les règles de reprise sont dans `Audio/ResumePolicy.swift` : comme les apps de
musique d'Apple, pause quand une autre app prend le son, reprise seulement si elle le permet et que la musique jouait.

## Coupures par une autre app

| # | Situation | Attendu |
|---|---|---|
| 1 | Musique, puis un vocal dans les messages Instagram/WhatsApp | La musique s'arrête pendant le vocal, reprend après si l'app le permet |
| 2 | Musique, puis ouvrir les messages Instagram sans rien lancer | Pause si Instagram prend le son ; l'app reste sur l'écran verrouillé |
| 3 | Musique, puis une vidéo YouTube | La musique s'arrête, reprend à la fin ou à la pause de la vidéo |
| 4 | Musique, appel reçu puis raccroché | Pause pendant l'appel, reprise après |
| 5 | Musique, appel reçu puis refusé | Reprise |
| 6 | Musique **en pause**, puis appel raccroché | Reste en pause |
| 7 | Musique, vocal, et pendant le vocal appuyer sur pause (écran verrouillé) | Reste en pause après le vocal |
| 8 | Musique, vocal, et pendant le vocal appuyer sur lecture | La musique repart tout de suite, pas de double reprise après |
| 9 | Musique, vocal, puis appel pendant le vocal | Reprise une fois tout fini |
| 10 | Titre lancé, appel dans la seconde (encore en chargement) | Reprise après l'appel |
| 11 | Siri, puis fin de Siri | Reprise |
| 12 | Après le cas 2, quitter Instagram | Reprise si Instagram le permet, sinon reste en pause, commandes toujours sur l'écran verrouillé |

## Écouteurs

| # | Situation | Attendu |
|---|---|---|
| 13 | Retirer les deux AirPods | Pause |
| 14 | Les remettre (moins de 30 min) | Reprise |
| 15 | Retirer les AirPods, appuyer sur lecture puis pause sur l'iPhone, les remettre | Pas de reprise |
| 16 | Retirer un seul AirPod | Pause (pas encore réglé) |
| 17 | Débrancher des écouteurs filaires | Pause, jamais sur le haut-parleur |
| 18 | Retirer les AirPods pendant un vocal | Pas de reprise sur le haut-parleur après le vocal |
| 19 | Connecter une enceinte Bluetooth | La musique ne se lance pas toute seule |

## Divers

| # | Situation | Attendu |
|---|---|---|
| 20 | Ouvrir l'app pendant que Spotify/Apple Music joue | Leur musique continue |
| 21 | Verrouiller l'iPhone pendant la lecture | La lecture continue, commandes sur l'écran verrouillé |
