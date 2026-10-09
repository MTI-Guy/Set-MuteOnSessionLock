# Set-MuteOnSessionLock

Petit utilitaire Windows qui **coupe le son au verrouillage de la session** et le **rétablit au déverrouillage**. Il tourne en arrière-plan, sans fenêtre, avec une icône (haut-parleur + cadenas) près de l'horloge.

## Fonctionnalités

- Verrouillage : coupe le son (s'il n'était pas déjà muet).
- Déverrouillage : rétablit le son, avec une notification Windows.
- Option « Rester muet au déverrouillage la nuit » : le son n'est pas rétabli si on déverrouille pendant la plage de nuit (22h–7h par défaut, réglable).
- Si la session s'est terminée pendant le verrouillage (redémarrage, fermeture), le son est rétabli au prochain démarrage.
- Menu de l'icône (clic gauche ou droit) : couper/rétablir le son, pause de la surveillance, option de nuit, paramètres, journal, quitter.
- Notification quand une nouvelle version est publiée ici (aucune mise à jour sans votre accord).

## Installation

Windows 10/11, Windows PowerShell 5.1 ou PowerShell 7. Aucun droit administrateur requis.

1. Téléchargez `Set-MuteOnSessionLock.ps1`.
2. Dans PowerShell :
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-MuteOnSessionLock.ps1 -Setup
   ```
3. Choisissez **I** (installer / mettre à jour). Le script est copié dans `%LOCALAPPDATA%\Programs\Set-MuteOnSessionLock\` et une tâche planifiée le lance à chaque ouverture de session.

Mise à jour : relancez la même commande (depuis le dossier installé) et choisissez **I**. Désinstallation : option **D**.

## Fichiers

| Élément | Emplacement |
|---|---|
| Script installé | `%LOCALAPPDATA%\Programs\Set-MuteOnSessionLock\` |
| Journal, paramètres, état | `%LOCALAPPDATA%\Set-MuteOnSessionLock\` |
| Tâche planifiée | `Set-MuteOnSessionLock` |

Paramètres (`MuteOnSessionLock.settings`) : `StayMutedAtNight` (`true`/`false`), `NightStartHour` et `NightEndHour` (0–23, la plage peut passer minuit).

## Statut

Fourni **tel quel, sans support** ni garantie. Vous pouvez m'écrire en ouvrant un ticket (onglet « Issues » du dépôt) : je répondrai quand je le pourrai, sans engagement de délai.

## Licence

[MIT](LICENSE) — © 2026 Mon Tech TI
