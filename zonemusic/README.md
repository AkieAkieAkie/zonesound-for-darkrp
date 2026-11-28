# Zone Music (DarkRP) - v6

Installation : copier `zonemusic` dans `garrysmod/addons/`. Rien a installer cote joueurs.
Pour YouTube / Spotify / recherche par titre : installer `zonemusic-resolver` (voir son README).

## Ce que /music accepte
- Lien mp3/ogg/webradio direct : toujours, sans resolveur
- Lien YouTube, SoundCloud : avec resolveur
- Lien Spotify : avec resolveur (le titre est recherche sur YouTube)
- Un titre : `/music daft punk one more time` (1er resultat YouTube)

## Commandes
/musicpos1, /musicpos2, /musiccreate <nom>, /musicdelete, /musiczones (admin)
/music <lien ou titre>, /musicstop (joueur dans la zone). Console : zonemusic_volume 0.5


## Lecteur et administration (v6)
F3 active la souris. Cliquer n’importe où sur le bandeau du petit lecteur le déroule ou le referme, même si le titre est long.
Les administrateurs reconnus par `Config.IsAdmin` disposent de boutons pour précédent/suivant sans vote, pause/reprise, arrêt et suppression individuelle de titres en attente.
L’arrêt demande confirmation et vide la file et l’historique. Les joueurs conservent les votes précédent/suivant.
La confirmation d’arrêt utilise une fenêtre native du jeu ; annuler ne modifie rien. La file reste utilisable sur les petits écrans et les longs titres sont tronqués sans masquer les boutons.
Le volume de la zone (0–2000 %, 100 % par défaut) multiplie le volume personnel de chaque auditeur, sans annuler sa sourdine ; la sortie finale reste plafonnée par `MaxVolume`.
Ces commandes sont vérifiées côté serveur et exigent que l’administrateur soit vivant dans la zone. Le volume commun reste actif jusqu’au redémarrage du serveur.

## Mise à jour
Remplacer les fichiers client ET serveur de l’addon, puis redémarrer le serveur. Garder `garrysmod/data/zonemusic/resolver_key.txt` et la configuration du résolveur : aucune clé ni aucun cookie ne sont inclus dans cette archive.
Vérifications en jeu : F3, clic sur un long titre, entrée/sortie de zone, contrôles admin, et volume de zone avec deux joueurs dont un en sourdine.

## Vérifications de cette version
Tests automatisés avec simulations des fonctions Garry’s Mod : permissions admin, pause/reprise, précédent/suivant, suppression par identifiant, arrêt et historique, F3, entrée/sortie de zone, mort du joueur, confirmation et respect de la sourdine.
Le HTML du lecteur a également été vérifié dans Chromium avec de longs titres et plusieurs tailles de fenêtre. Ces contrôles ne remplacent pas un essai sur le serveur Garry’s Mod : la lecture réelle, les effets 3D, les pochettes et les interactions avec les autres addons restent à vérifier en jeu.

Depuis la racine du dépôt :
```
lua zonemusic/tests/check_syntax.lua
lua zonemusic/tests/admin_controls.lua
lua zonemusic/tests/client_controls.lua
```
