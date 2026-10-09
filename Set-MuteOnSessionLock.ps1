#Requires -Version 5.1
# Set-MuteOnSessionLock.ps1
<#
.SYNOPSIS
    Coupe automatiquement le son du poste au verrouillage de la session Windows et le
    rétablit au déverrouillage. Tourne en arrière-plan, sans fenêtre, avec une icône
    dans la zone de notification.

.DESCRIPTION
    - Verrouillage : coupe le son (s'il n'était pas déjà muet).
    - Déverrouillage : rétablit le son s'il a été coupé par ce script (notification Windows),
      sauf si le paramètre « Rester muet la nuit » est activé et qu'on est dans la plage de
      nuit (22h-7h par défaut ; réglable dans MuteOnSessionLock.settings).
    - Démarrage : si la session précédente s'est terminée pendant le verrouillage
      (redémarrage, fermeture), rétablit le son (notification Windows).
    - Icône (haut-parleur + cadenas) dans la zone de notification, menu au clic gauche ou droit :
      couper/rétablir le son, mettre la surveillance en pause, ouvrir le journal, quitter.
    - Au démarrage, signale par notification si une nouvelle version est publiée sur GitHub.

    Installation, mise à jour et désinstallation : mode -Setup (interactif). Le script est
    copié dans %LOCALAPPDATA%\Programs\Set-MuteOnSessionLock\ et lancé à chaque ouverture de
    session par une tâche planifiée, sans fenêtre (conhost.exe --headless : sous Windows 11,
    Windows Terminal ignore -WindowStyle Hidden et laisse une fenêtre réduite dans la barre
    des tâches). Journal, paramètres et fichier d'état sont dans
    %LOCALAPPDATA%\Set-MuteOnSessionLock\.

.PARAMETER Setup
    Mode interactif : installer / mettre à jour, mettre la tâche en pause, désinstaller.
    Ne démarre pas la surveillance dans la console courante.

.EXAMPLE
    .\Set-MuteOnSessionLock.ps1 -Setup
    Installe (ou met à jour) le script et la tâche planifiée, puis démarre la surveillance.

.NOTES
    Auteur  : Mon Tech TI (Dave) avec assistance Claude
    Licence : MIT (voir LICENSE) — fourni tel quel, sans support
    Version : 1.2.0
    Statut  : Prod
    Date    : 2026-10-09
#>

param(
    [switch]$Setup
)

# Comparée à la version publiée sur GitHub (voir Test-ScriptSelfUpdate plus bas) :
# Majeur.Mineur.Patch — incrémenter le Mineur (reset Patch à 0) pour une nouvelle
# fonctionnalité, le Patch pour une résolution de bug.
$ScriptVersion = "1.2.0"

# ── Encodage de la console (accents et caractères de bordure ═) ─────────────────
# Le fichier doit être enregistré en UTF-8 AVEC BOM (sinon PS 5.1 le décode en ANSI) ;
# le forçage ci-dessous corrige en plus l'affichage de la console héritée.
if ($Host.Name -eq 'ConsoleHost') {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        chcp 65001 > $null
    }
    catch {}
}

function Show-ScriptBanner {
    param([string]$Title)
    $inner = " $Title "
    $width = $inner.Length
    Write-Host ""
    Write-Host "  ╔$('═' * $width)╗" -ForegroundColor Cyan
    Write-Host "  ║$inner║" -ForegroundColor Cyan
    Write-Host "  ╚$('═' * $width)╝" -ForegroundColor Cyan
    Write-Host "  Version du script : $ScriptVersion" -ForegroundColor DarkGray
    Write-Host ""
}

Show-ScriptBanner -Title "Set-MuteOnSessionLock.ps1"
if ([version]$ScriptVersion -lt [version]"1.0.0") {
    Write-Host "  ⚠ SCRIPT EN DÉVELOPPEMENT — NON VALIDÉ EN PRODUCTION" -ForegroundColor Red
    Write-Host ""
}
Write-Host "  Ce que fait ce script :"
Write-Host "   - Au verrouillage de la session Windows : coupe le son."
Write-Host "   - Au déverrouillage : rétablit le son (notification Windows)."
Write-Host "   - Au démarrage : rétablit le son s'il est resté coupé par une session"
Write-Host "     terminée pendant le verrouillage (notification Windows)."
Write-Host "   - Clic droit sur l'icône près de l'horloge : son, pause, journal, quitter."
Write-Host ""

# ── Emplacements ────────────────────────────────────────────────────────────────
$TaskName        = "Set-MuteOnSessionLock"
$ScriptFileName  = "Set-MuteOnSessionLock.ps1"
# Standard Windows par utilisateur : programme dans Programs\, données (journal, paramètres,
# état) à part, sans droits administrateur.
$InstallDir      = Join-Path $env:LOCALAPPDATA "Programs\Set-MuteOnSessionLock"
$DataDir         = Join-Path $env:LOCALAPPDATA "Set-MuteOnSessionLock"
$InstalledScript = Join-Path $InstallDir $ScriptFileName
$LogPath         = Join-Path $DataDir "MuteOnSessionLock.log"
$StatePath       = Join-Path $DataDir "MuteOnSessionLock.state"
$SettingsPath    = Join-Path $DataDir "MuteOnSessionLock.settings"
# Emplacement des versions 1.0 / 1.1 (migré à l'installation)
$LegacyDir       = Join-Path $env:LOCALAPPDATA "MTI\Set-MuteOnSessionLock"

# ── Auto-vérification de version depuis GitHub (dépôt public, sans gh) ─────────
$Owner = "MTI-Guy"
$Repo  = "Set-MuteOnSessionLock"
$RemoteScriptUrl = "https://raw.githubusercontent.com/$Owner/$Repo/main/$ScriptFileName"

$Utf8BomEncoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'utf8' }

# Contenu du script publié sur GitHub (tableau de lignes), ou $null si injoignable.
function Get-RemoteScriptLines {
    try {
        $response = Invoke-WebRequest -Uri $RemoteScriptUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        # Décodage explicite des octets (UTF-8) : évite les erreurs d'encodage de PS 5.1.
        $stream = New-Object System.IO.MemoryStream
        $response.RawContentStream.CopyTo($stream)
        $text = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        # Retire le BOM s'il est restitué comme caractère U+FEFF : sans cela, Set-Content
        # ajouterait un second BOM et le script ne parserait plus.
        $remoteLines = @($text.TrimStart([char]0xFEFF) -split "\r?\n")
        if ($remoteLines.Count -eq 0) { return $null }
        return , $remoteLines
    }
    catch {
        return $null
    }
}

function Get-ScriptVersionFromLines {
    param($Lines)
    $versionMatch = $Lines | Select-String -Pattern '\$ScriptVersion\s*=\s*"([\d.]+)"' | Select-Object -First 1
    if ($versionMatch) { return $versionMatch.Matches[0].Groups[1].Value }
    return $null
}

# Retourne $true si le script a été mis à jour et relancé : l'appelant doit alors s'arrêter
# avec return (jamais exit, qui tuerait la console intégrée de VS Code).
function Test-ScriptSelfUpdate {
    param([string]$CurrentVersion)

    $remoteLines = Get-RemoteScriptLines
    if (-not $remoteLines) { return $false }
    $remoteVersion = Get-ScriptVersionFromLines -Lines $remoteLines
    if (-not $remoteVersion) { return $false }
    try {
        if ([version]$remoteVersion -le [version]$CurrentVersion) { return $false }
    }
    catch {
        return $false
    }

    Write-Host ""
    Write-Host "  Une nouvelle version de $ScriptFileName est disponible : $remoteVersion (actuelle : $CurrentVersion)" -ForegroundColor Green
    $reponse = Read-Host "  Voulez-vous mettre à jour maintenant ? (O/N)"
    if ($reponse -notmatch '^[Oo]$') { return $false }

    try {
        Set-Content -Path $PSCommandPath -Value $remoteLines -Encoding $Utf8BomEncoding
    }
    catch {
        Write-Warning "Échec de la mise à jour : $($_.Exception.Message)"
        return $false
    }

    Write-Host "  ✅ Mis à jour vers la version $remoteVersion. Relance en cours..." -ForegroundColor Green
    Write-Host ""
    $relaunchExe = (Get-Process -Id $PID).Path
    Start-Process $relaunchExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Setup"
    return $true
}

# ════════════════════════════════════════════════════════════════════════════════
#  MODE -Setup : installation / mise à jour / pause / désinstallation
# ════════════════════════════════════════════════════════════════════════════════

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-WatcherTaskAction {
    New-ScheduledTaskAction -Execute "conhost.exe" -Argument "--headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`""
}

# Instances de surveillance en cours (hors console -Setup courante).
function Get-WatcherProcess {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.CommandLine -like "*$ScriptFileName*" -and $_.CommandLine -notlike '*-Setup*' -and $_.ProcessId -ne $PID }
}

function Stop-Watcher {
    foreach ($p in @(Get-WatcherProcess)) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            Write-Host "  ✅ Instance arrêtée (PID $($p.ProcessId))" -ForegroundColor Green
        }
        catch {
            Write-Host "  ❌ Échec de l'arrêt du PID $($p.ProcessId) : $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# Migre journal, paramètres et état des versions 1.0 / 1.1 vers le nouvel emplacement,
# puis supprime l'ancien dossier.
function Move-LegacyInstall {
    if (-not (Test-Path $LegacyDir)) { return }
    try {
        foreach ($f in 'MuteOnSessionLock.log', 'MuteOnSessionLock.state', 'MuteOnSessionLock.settings') {
            $src = Join-Path $LegacyDir $f
            if ((Test-Path $src) -and -not (Test-Path (Join-Path $DataDir $f))) {
                Move-Item -Path $src -Destination $DataDir -ErrorAction Stop
            }
        }
        Remove-Item -Path $LegacyDir -Recurse -Force -ErrorAction Stop
        $legacyParent = Split-Path $LegacyDir -Parent
        if ((Test-Path $legacyParent) -and -not (Get-ChildItem $legacyParent -Force)) {
            Remove-Item $legacyParent -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  ✅ Ancien dossier migré vers $DataDir : $LegacyDir supprimé" -ForegroundColor Green
    }
    catch {
        Write-Host "  ⚠ Migration de l'ancien dossier $LegacyDir incomplète : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Install-Watcher {
    # 1. Copie du script dans le dossier d'installation (hors OneDrive / clone git)
    try {
        New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction Stop | Out-Null
        New-Item -ItemType Directory -Path $DataDir -Force -ErrorAction Stop | Out-Null
        if ($PSCommandPath -ne $InstalledScript) {
            Copy-Item -Path $PSCommandPath -Destination $InstalledScript -Force -ErrorAction Stop
        }
        $installedVersion = Get-ScriptVersionFromLines -Lines (Get-Content $InstalledScript -Encoding UTF8)
        if ($installedVersion -eq $ScriptVersion) {
            Write-Host "  ✅ Script installé : $InstalledScript (version $installedVersion)" -ForegroundColor Green
        }
        else {
            Write-Host "  ❌ Version installée constatée ($installedVersion) différente de la version attendue ($ScriptVersion)." -ForegroundColor Red
            return
        }
    }
    catch {
        Write-Host "  ❌ Échec de la copie du script : $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    # 2. Tâche planifiée (création, ou mise à jour de l'action en gardant le reste)
    try {
        # Sans limite de durée (défaut Windows : arrêt après 72 h) et aussi sur batterie.
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Set-ScheduledTask -TaskName $TaskName -Action (New-WatcherTaskAction) -Settings $settings -ErrorAction Stop | Out-Null
        }
        else {
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
            $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $TaskName -Action (New-WatcherTaskAction) -Trigger $trigger -Principal $principal -Settings $settings `
                -Description "Coupe le son au verrouillage de session, le rétablit au déverrouillage (MTI-Guy/Set-MuteOnSessionLock)" -ErrorAction Stop | Out-Null
        }
        $verif = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($verif -and $verif.Actions[0].Execute -eq 'conhost.exe' -and $verif.Actions[0].Arguments -like "*$InstalledScript*") {
            Write-Host "  ✅ Tâche planifiée '$TaskName' : lancement invisible à l'ouverture de session" -ForegroundColor Green
        }
        else {
            Write-Host "  ❌ La tâche '$TaskName' n'a pas l'action attendue après coup." -ForegroundColor Red
            return
        }
    }
    catch {
        Write-Host "  ❌ Échec de la configuration de la tâche planifiée : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "     Si « Accès refusé » : relancez ce script dans une console PowerShell 'Exécuter en tant qu'administrateur'." -ForegroundColor Yellow
        return
    }

    # 3. Redémarrage de la surveillance avec la version installée
    Stop-Watcher
    Start-Sleep -Seconds 2
    Move-LegacyInstall
    try {
        Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    }
    catch {
        Write-Host "  ❌ Échec du démarrage de la tâche : $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    Start-Sleep -Seconds 6
    $running = @(Get-WatcherProcess | Where-Object { $_.CommandLine -like "*$InstalledScript*" })
    if ($running.Count -gt 0) {
        Write-Host "  ✅ Surveillance démarrée (PID $($running[0].ProcessId)) : l'icône est près de l'horloge." -ForegroundColor Green
    }
    else {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName
        Write-Host "  ❌ La surveillance ne tourne pas après le démarrage de la tâche (dernier résultat : $($info.LastTaskResult))." -ForegroundColor Red
        Write-Host "     Relancez-la depuis une console NON administrateur :" -ForegroundColor Yellow
        Write-Host "     Start-ScheduledTask -TaskName `"$TaskName`"" -ForegroundColor Yellow
    }
}

function Uninstall-Watcher {
    Write-Host ""
    Write-Host "  Ce qui sera supprimé :" -ForegroundColor Yellow
    Write-Host "   - la surveillance en cours (icône près de l'horloge)"
    Write-Host "   - la tâche planifiée '$TaskName'"
    Write-Host "   - le dossier $InstallDir (script installé)"
    Write-Host "   - le dossier $DataDir (journal, paramètres, fichier d'état)"
    $ok = Read-Host "  Tapez OUI pour désinstaller"
    if ($ok -ne 'OUI') {
        Write-Host "  Désinstallation annulée, aucune modification." -ForegroundColor Yellow
        return
    }

    # Ne pas laisser le poste muet si le son a été coupé par le script
    if (Test-Path $StatePath) {
        try { [AudioEndpointVolume]::SetMute($false) } catch {}
    }
    Stop-Watcher
    if (Test-Path $DataDir) {
        Remove-Item -Path $DataDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $DataDir) {
            Write-Host "  ❌ Le dossier $DataDir existe toujours après coup." -ForegroundColor Red
        }
        else {
            Write-Host "  ✅ Dossier des données supprimé" -ForegroundColor Green
        }
    }
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        }
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Write-Host "  ❌ La tâche '$TaskName' existe toujours après coup." -ForegroundColor Red
        }
        else {
            Write-Host "  ✅ Tâche planifiée supprimée" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  ❌ Échec de la suppression de la tâche : $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "     Si « Accès refusé » : relancez ce script dans une console PowerShell 'Exécuter en tant qu'administrateur'." -ForegroundColor Yellow
    }
    if ($PSCommandPath -eq $InstalledScript) {
        Write-Host "  ⚠ Ce script tourne depuis le dossier d'installation : supprimez-le à la main une fois cette console fermée :" -ForegroundColor Yellow
        Write-Host "     Remove-Item -Recurse -Force `"$InstallDir`"" -ForegroundColor Yellow
    }
    elseif (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $InstallDir) {
            Write-Host "  ❌ Le dossier $InstallDir existe toujours après coup." -ForegroundColor Red
        }
        else {
            Write-Host "  ✅ Dossier d'installation supprimé" -ForegroundColor Green
        }
    }
}

# ════════════════════════════════════════════════════════════════════════════════
#  Code natif : volume (Core Audio), icône, surveillance des sessions
# ════════════════════════════════════════════════════════════════════════════════

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Sous PowerShell 7 (.NET moderne), WinForms est éclaté en plusieurs assemblies absentes
# sous Windows PowerShell 5.1. On instancie réellement un Form pour forcer le chargement
# de toutes ses dépendances, puis on référence toutes les assemblies chargées pour éviter
# les erreurs CS0012 à la compilation ci-dessous.
$tempForm = New-Object System.Windows.Forms.Form
$tempForm.Dispose()
$refs = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { -not $_.IsDynamic -and $_.Location } | Select-Object -ExpandProperty Location -Unique

# Détection du verrouillage via WTSRegisterSessionNotification (API Windows native), plus
# fiable que Microsoft.Win32.SystemEvents.SessionSwitch sous PowerShell 7 / .NET moderne.
Add-Type -ReferencedAssemblies $refs -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice
{
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator
{
    int NotImpl1();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume
{
    int NotImpl1();
    int NotImpl2();
    int GetChannelCount(out int pnChannelCount);
    int SetMasterVolumeLevel(float fLevelDB, Guid pguidEventContext);
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int GetMasterVolumeLevel(out float pfLevelDB);
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int SetChannelVolumeLevel(int nChannel, float fLevelDB, Guid pguidEventContext);
    int SetChannelVolumeLevelScalar(int nChannel, float fLevel, Guid pguidEventContext);
    int GetChannelVolumeLevel(int nChannel, out float pfLevelDB);
    int GetChannelVolumeLevelScalar(int nChannel, out float pfLevel);
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    int GetVolumeStepInfo(out int pnStep, out int pnStepCount);
    int VolumeStepUp(Guid pguidEventContext);
    int VolumeStepDown(Guid pguidEventContext);
    int QueryHardwareSupport(out int pdwHardwareSupportMask);
    int GetVolumeRange(out float pflVolumeMindB, out float pflVolumeMaxdB, out float pflVolumeIncrementdB);
}

public class AudioEndpointVolume
{
    private static IAudioEndpointVolume GetVolumeObject()
    {
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        IMMDevice device;
        enumerator.GetDefaultAudioEndpoint(0, 1, out device); // eRender, eMultimedia
        Guid iid = typeof(IAudioEndpointVolume).GUID;
        object epv;
        device.Activate(ref iid, 1, IntPtr.Zero, out epv);
        return (IAudioEndpointVolume)epv;
    }

    public static void SetMute(bool mute)
    {
        GetVolumeObject().SetMute(mute, Guid.Empty);
    }

    public static bool GetMute()
    {
        bool muted;
        GetVolumeObject().GetMute(out muted);
        return muted;
    }
}

// Icône dessinée en vectoriel (haut-parleur + cadenas) : aucun fichier .ico à distribuer.
// Grille de 32 x 32 mise à l'échelle de la taille demandée.
public static class TrayIconPainter
{
    public static Icon Create(bool paused)
    {
        int size = SystemInformation.SmallIconSize.Width;
        using (var bmp = Draw(size, paused))
        {
            return Icon.FromHandle(bmp.GetHicon());
        }
    }

    public static Bitmap Draw(int size, bool paused)
    {
        var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            g.ScaleTransform(size / 32f, size / 32f);

            Color speakerColor = paused ? Color.FromArgb(150, 150, 150) : Color.FromArgb(0, 120, 215);
            Color lockColor = paused ? Color.FromArgb(230, 140, 0) : Color.FromArgb(255, 185, 0);
            Color lockDark = Color.FromArgb(90, 60, 0);

            // Haut-parleur : boîtier + pavillon
            using (var b = new SolidBrush(speakerColor))
            {
                g.FillPolygon(b, new PointF[] {
                    new PointF(1, 9), new PointF(6, 9), new PointF(13, 2),
                    new PointF(13, 24), new PointF(6, 17), new PointF(1, 17) });
            }
            // Ondes sonores
            using (var p = new Pen(speakerColor, 2.4f))
            {
                p.StartCap = LineCap.Round;
                p.EndCap = LineCap.Round;
                g.DrawArc(p, 10, 8, 7, 10, -55, 110);
                g.DrawArc(p, 10, 3, 13, 20, -55, 110);
            }

            // Cadenas en bas à droite
            using (var shackle = new Pen(lockDark, 4.6f))
            using (var shackleFill = new Pen(lockColor, 2.4f))
            using (var body = new SolidBrush(lockColor))
            using (var outline = new Pen(lockDark, 1.4f))
            using (var hole = new SolidBrush(lockDark))
            {
                g.DrawArc(shackle, 21.5f, 14, 8, 9, 180, 180);
                g.DrawLine(shackle, 21.5f, 18.5f, 21.5f, 21);
                g.DrawLine(shackle, 29.5f, 18.5f, 29.5f, 21);
                g.DrawArc(shackleFill, 21.5f, 14, 8, 9, 180, 180);
                g.DrawLine(shackleFill, 21.5f, 18.5f, 21.5f, 21);
                g.DrawLine(shackleFill, 29.5f, 18.5f, 29.5f, 21);
                g.FillRectangle(body, 18.5f, 20.5f, 14, 11);
                g.DrawRectangle(outline, 18.5f, 20.5f, 13, 10.8f);
                g.FillEllipse(hole, 24, 23.5f, 3, 3);
                g.FillRectangle(hole, 24.8f, 25.5f, 1.4f, 3.5f);
            }

            // En pause : deux barres orange en haut à gauche
            if (paused)
            {
                using (var b = new SolidBrush(Color.FromArgb(230, 140, 0)))
                {
                    g.FillRectangle(b, 0, 0, 3.5f, 9);
                    g.FillRectangle(b, 5.5f, 0, 3.5f, 9);
                }
            }
        }
        return bmp;
    }
}

public class SessionLockWatcher : Form
{
    private const int WM_WTSSESSION_CHANGE = 0x02B1;
    private const int NOTIFY_FOR_THIS_SESSION = 0;
    private const int WTS_SESSION_LOCK = 0x7;
    private const int WTS_SESSION_UNLOCK = 0x8;

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSRegisterSessionNotification(IntPtr hWnd, int dwFlags);

    private bool mutedByWatcher = false;
    private readonly string logPath;
    private readonly string statePath;
    private readonly NotifyIcon trayIcon;
    private readonly Icon activeIcon;
    private readonly Icon pausedIcon;
    private bool paused = false;
    private ToolStripMenuItem muteItem;
    private ToolStripMenuItem pauseItem;
    private ToolStripMenuItem nightItem;

    // Paramètres (fichier clé=valeur) : au déverrouillage, rester muet pendant la nuit.
    private readonly string settingsPath;
    private bool stayMutedAtNight = false;
    private int nightStartHour = 22;
    private int nightEndHour = 7;

    public SessionLockWatcher(string logPath, string statePath, string settingsPath, string scriptVersion)
    {
        this.logPath = logPath;
        this.statePath = statePath;
        this.settingsPath = settingsPath;
        LoadSettings();
        activeIcon = TrayIconPainter.Create(false);
        pausedIcon = TrayIconPainter.Create(true);
        trayIcon = new NotifyIcon();
        trayIcon.ContextMenuStrip = BuildMenu(scriptVersion);
        // Le menu s'ouvre aussi au clic gauche (le clic droit est géré par ContextMenuStrip).
        trayIcon.MouseUp += (s, e) =>
        {
            if (e.Button == MouseButtons.Left) ShowTrayMenu();
        };
        UpdateTrayState();
        trayIcon.Visible = true;
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        Opacity = 0;
        Size = new Size(0, 0);
        CreateControl();
        Log("Watcher initialise (handle=" + Handle + ")");
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        bool ok = WTSRegisterSessionNotification(Handle, NOTIFY_FOR_THIS_SESSION);
        Log("WTSRegisterSessionNotification -> " + ok);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_WTSSESSION_CHANGE)
        {
            int reason = m.WParam.ToInt32();
            Log("WM_WTSSESSION_CHANGE recu, wParam=" + reason + " (" + DescribeSessionChange(reason) + ")");
            try
            {
                if (reason == WTS_SESSION_LOCK)
                {
                    if (paused)
                    {
                        Log("Surveillance en pause, son non coupe");
                    }
                    else if (!AudioEndpointVolume.GetMute())
                    {
                        AudioEndpointVolume.SetMute(true);
                        mutedByWatcher = true;
                        WriteState();
                        Log("Son coupe");
                    }
                    else
                    {
                        Log("Deja muet, rien a faire");
                    }
                }
                else if (reason == WTS_SESSION_UNLOCK)
                {
                    LoadSettings();
                    if (mutedByWatcher && stayMutedAtNight && IsNight())
                    {
                        // Le son reste muet : on n'a plus rien à rétablir au prochain démarrage.
                        mutedByWatcher = false;
                        DeleteState();
                        Log("Son laisse muet : deverrouillage de nuit (" + nightStartHour + "h-" + nightEndHour + "h)");
                        Notify("Son laissé coupé : déverrouillage de nuit (" + nightStartHour + "h-" + nightEndHour + "h).");
                    }
                    else if (mutedByWatcher)
                    {
                        AudioEndpointVolume.SetMute(false);
                        mutedByWatcher = false;
                        DeleteState();
                        Log("Son retabli");
                        Notify("Son rétabli au déverrouillage de la session.");
                    }
                    else
                    {
                        Log("Pas remis (mutedByWatcher = false)");
                    }
                }
            }
            catch (Exception ex)
            {
                Log("ERREUR : " + ex);
            }
        }
        base.WndProc(ref m);
    }

    // Menu du clic droit sur l'icône de la zone de notification.
    private ContextMenuStrip BuildMenu(string scriptVersion)
    {
        var menu = new ContextMenuStrip();

        var title = new ToolStripMenuItem("Set-MuteOnSessionLock v" + scriptVersion);
        title.Enabled = false;
        menu.Items.Add(title);
        menu.Items.Add(new ToolStripSeparator());

        muteItem = new ToolStripMenuItem("Couper le son", null, (s, e) => ToggleMute());
        menu.Items.Add(muteItem);

        pauseItem = new ToolStripMenuItem("Mettre la surveillance en pause", null, (s, e) => TogglePause());
        menu.Items.Add(pauseItem);

        nightItem = new ToolStripMenuItem("", null, (s, e) => ToggleStayMutedAtNight());
        menu.Items.Add(nightItem);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Ouvrir le fichier de paramètres", null, (s, e) => OpenSettings()));
        menu.Items.Add(new ToolStripMenuItem("Ouvrir le journal", null, (s, e) => OpenLog()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quitter (arrêter la surveillance)", null, (s, e) => QuitWatcher()));

        // Libellé du son mis à jour à chaque ouverture du menu (le son a pu changer
        // par la touche de volume entre-temps).
        menu.Opening += (s, e) =>
        {
            LoadSettings();
            UpdateNightItem();
            try { muteItem.Text = AudioEndpointVolume.GetMute() ? "Rétablir le son" : "Couper le son"; }
            catch (Exception ex) { Log("ERREUR lecture etat du son : " + ex.Message); }
        };
        return menu;
    }

    // Ouvre le menu contextuel au clic gauche (méthode interne de NotifyIcon, seule façon
    // d'obtenir le même comportement et le même positionnement que le clic droit).
    private void ShowTrayMenu()
    {
        try
        {
            var method = typeof(NotifyIcon).GetMethod("ShowContextMenu",
                System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
            method.Invoke(trayIcon, null);
        }
        catch (Exception ex) { Log("ERREUR ouverture du menu (clic gauche) : " + ex.Message); }
    }

    private static string DescribeSessionChange(int reason)
    {
        switch (reason)
        {
            case 1: return "connexion de la console";
            case 2: return "deconnexion de la console";
            case 3: return "connexion a distance";
            case 4: return "deconnexion a distance";
            case 5: return "ouverture de session (logon)";
            case 6: return "fermeture de session (logoff)";
            case 7: return "verrouillage de la session";
            case 8: return "deverrouillage de la session";
            case 9: return "changement de controle a distance";
            case 10: return "creation de session";
            case 11: return "fin de session";
            default: return "evenement de session inconnu";
        }
    }

    // Vrai si l'heure actuelle est dans la plage de nuit (peut chevaucher minuit).
    private bool IsNight()
    {
        int h = DateTime.Now.Hour;
        if (nightStartHour == nightEndHour) return false;
        return nightStartHour < nightEndHour
            ? (h >= nightStartHour && h < nightEndHour)
            : (h >= nightStartHour || h < nightEndHour);
    }

    private void LoadSettings()
    {
        try
        {
            if (!System.IO.File.Exists(settingsPath)) { SaveSettings(); return; }
            foreach (string line in System.IO.File.ReadAllLines(settingsPath))
            {
                string l = line.Trim();
                if (l.Length == 0 || l.StartsWith("#")) continue;
                int i = l.IndexOf('=');
                if (i < 1) continue;
                string key = l.Substring(0, i).Trim();
                string val = l.Substring(i + 1).Trim();
                int n;
                if (key == "StayMutedAtNight") stayMutedAtNight = val.Equals("true", StringComparison.OrdinalIgnoreCase);
                else if (key == "NightStartHour" && int.TryParse(val, out n) && n >= 0 && n <= 23) nightStartHour = n;
                else if (key == "NightEndHour" && int.TryParse(val, out n) && n >= 0 && n <= 23) nightEndHour = n;
            }
        }
        catch (Exception ex) { Log("ERREUR lecture des parametres : " + ex.Message); }
    }

    private void SaveSettings()
    {
        try
        {
            System.IO.File.WriteAllLines(settingsPath, new string[] {
                "# Au deverrouillage : true = le son reste coupe pendant la nuit, false = toujours retabli.",
                "StayMutedAtNight=" + (stayMutedAtNight ? "true" : "false"),
                "# Plage de nuit (heures 0-23, peut chevaucher minuit) : de NightStartHour inclus a NightEndHour exclu.",
                "NightStartHour=" + nightStartHour,
                "NightEndHour=" + nightEndHour });
        }
        catch (Exception ex) { Log("ERREUR ecriture des parametres : " + ex.Message); }
    }

    private void UpdateNightItem()
    {
        nightItem.Text = (stayMutedAtNight ? "✔ " : "") + "Rester muet au déverrouillage la nuit (" + nightStartHour + "h-" + nightEndHour + "h)";
    }

    private void ToggleStayMutedAtNight()
    {
        LoadSettings();
        stayMutedAtNight = !stayMutedAtNight;
        SaveSettings();
        UpdateNightItem();
        Log(stayMutedAtNight ? "Parametre : son laisse muet au deverrouillage de nuit (menu)" : "Parametre : son toujours retabli au deverrouillage (menu)");
    }

    private void OpenSettings()
    {
        try
        {
            if (!System.IO.File.Exists(settingsPath)) SaveSettings();
            System.Diagnostics.Process.Start("notepad.exe", "\"" + settingsPath + "\"");
        }
        catch (Exception ex) { Log("ERREUR ouverture des parametres : " + ex.Message); }
    }

    private void ToggleMute()
    {
        try
        {
            bool mute = !AudioEndpointVolume.GetMute();
            AudioEndpointVolume.SetMute(mute);
            Log(mute ? "Son coupe (menu)" : "Son retabli (menu)");
        }
        catch (Exception ex) { Log("ERREUR menu son : " + ex.Message); }
    }

    private void TogglePause()
    {
        paused = !paused;
        UpdateTrayState();
        Log(paused ? "Surveillance mise en pause (menu)" : "Surveillance reprise (menu)");
        Notify(paused
            ? "Surveillance en pause : le son ne sera plus coupé au verrouillage."
            : "Surveillance reprise : le son sera coupé au verrouillage.");
    }

    private void UpdateTrayState()
    {
        trayIcon.Icon = paused ? pausedIcon : activeIcon;
        trayIcon.Text = paused
            ? "Set-MuteOnSessionLock : EN PAUSE"
            : "Set-MuteOnSessionLock : son coupé au verrouillage";
        pauseItem.Text = paused ? "Reprendre la surveillance" : "Mettre la surveillance en pause";
    }

    private void OpenLog()
    {
        try { System.Diagnostics.Process.Start("notepad.exe", "\"" + logPath + "\""); }
        catch (Exception ex) { Log("ERREUR ouverture du journal : " + ex.Message); }
    }

    private void QuitWatcher()
    {
        Log("Arret demande depuis le menu");
        trayIcon.Visible = false;
        Application.Exit();
    }

    public void Notify(string message)
    {
        try
        {
            trayIcon.ShowBalloonTip(5000, "Set-MuteOnSessionLock", message, ToolTipIcon.Info);
            Log("Notification : " + message);
        }
        catch (Exception ex) { Log("ERREUR notification : " + ex.Message); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing && trayIcon != null)
        {
            trayIcon.Visible = false;
            trayIcon.Dispose();
        }
        base.Dispose(disposing);
    }

    // Fichier témoin : présent tant que le son est coupé par le watcher. S'il reste
    // après un redémarrage/fermeture de session pendant le verrouillage, le son est
    // rétabli au prochain démarrage du script.
    private void WriteState()
    {
        try { System.IO.File.WriteAllText(statePath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")); }
        catch (Exception ex) { Log("ERREUR ecriture fichier d'etat : " + ex.Message); }
    }

    private void DeleteState()
    {
        try { System.IO.File.Delete(statePath); }
        catch (Exception ex) { Log("ERREUR suppression fichier d'etat : " + ex.Message); }
    }

    private void Log(string message)
    {
        try
        {
            System.IO.File.AppendAllText(logPath, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " - " + message + Environment.NewLine);
        }
        catch { }
    }
}
'@

# ── Mode -Setup ─────────────────────────────────────────────────────────────────
if ($Setup) {
    if (Test-ScriptSelfUpdate -CurrentVersion $ScriptVersion) { return }

    if (-not (Test-IsAdmin)) {
        Write-Host "  ℹ Console non administrateur : suffisant pour une nouvelle installation." -ForegroundColor DarkGray
        Write-Host "    Si une étape échoue avec « Accès refusé » (tâche créée en administrateur), relancez en administrateur." -ForegroundColor DarkGray
        Write-Host ""
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $running = @(Get-WatcherProcess)
    Write-Host "  État actuel :"
    if ($task) {
        $invisible = $task.Actions[0].Execute -eq 'conhost.exe' -and $task.Actions[0].Arguments -like "*$InstalledScript*"
        Write-Host "   - Tâche planifiée : $($task.State) (niveau : $($task.Principal.RunLevel))"
        if (-not $invisible) {
            Write-Host "   - ⚠ La tâche ne lance pas la copie installée en mode invisible : choisissez (I)." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "   - Tâche planifiée : absente (pas encore installé)"
    }
    if (Test-Path $InstalledScript) {
        Write-Host "   - Script installé : version $(Get-ScriptVersionFromLines -Lines (Get-Content $InstalledScript -Encoding UTF8)) ($InstalledScript)"
    }
    if ($running.Count -gt 0) {
        Write-Host "   - Surveillance en cours : PID $(($running | ForEach-Object { $_.ProcessId }) -join ', ')"
    }
    else {
        Write-Host "   - Surveillance en cours : aucune"
    }
    Write-Host ""
    Write-Host "  [I] Installer / mettre à jour (version $ScriptVersion) et démarrer la surveillance"
    if ($task) {
        Write-Host "  [P] $(if ($task.State -eq 'Disabled') { 'Réactiver' } else { 'Mettre en pause' }) la tâche planifiée (démarrage à l'ouverture de session)"
        Write-Host "  [D] Désinstaller"
    }
    Write-Host "  [Q] Quitter"
    $choix = Read-Host "  Votre choix"

    switch ($choix.ToUpper()) {
        'I' { Install-Watcher }
        'P' {
            if (-not $task) { Write-Host "  Aucune tâche à mettre en pause."; break }
            $cible = if ($task.State -eq 'Disabled') { 'Ready' } else { 'Disabled' }
            try {
                if ($task.State -eq 'Disabled') {
                    Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
                }
                else {
                    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
                }
                $verif = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
                if ($verif -and $verif.State -eq $cible) {
                    Write-Host "  ✅ Tâche $(if ($cible -eq 'Disabled') { 'mise en pause' } else { 'réactivée' }) (état confirmé : $($verif.State))." -ForegroundColor Green
                }
                else {
                    Write-Host "  ❌ État constaté ($($verif.State)) différent du résultat attendu ($cible)." -ForegroundColor Red
                }
            }
            catch {
                Write-Host "  ❌ Échec du changement d'état de la tâche : $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "     Si « Accès refusé » : relancez ce script dans une console PowerShell 'Exécuter en tant qu'administrateur'." -ForegroundColor Yellow
            }
        }
        'D' {
            if (-not $task -and -not (Test-Path $InstallDir)) { Write-Host "  Rien à désinstaller."; break }
            Uninstall-Watcher
        }
        default { Write-Host "  Aucune action effectuée." }
    }

    Write-Host ""
    Write-Host "  PROCHAINES ÉTAPES / RAPPELS :" -ForegroundColor Cyan
    Write-Host "   - Icône près de l'horloge (clic droit) : son, pause, journal, quitter."
    Write-Host "   - Journal : $LogPath"
    Write-Host "   - Mise à jour plus tard : relancez cette commande et choisissez (I) :"
    Write-Host "     powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstalledScript`" -Setup"
    Write-Host ""
    return
}

# ════════════════════════════════════════════════════════════════════════════════
#  Mode surveillance (lancé par la tâche planifiée, sans fenêtre)
# ════════════════════════════════════════════════════════════════════════════════

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

# Nettoyage du journal s'il devient trop gros (vérifié à chaque démarrage).
$maxLogSizeBytes = 5MB
if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt $maxLogSizeBytes) {
    Remove-Item $LogPath -Force
}

function Write-WatcherLog {
    param([string]$Message)
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Message" | Add-Content -Path $LogPath -Encoding UTF8
}

Write-WatcherLog "--- Demarrage script v$ScriptVersion (PID $PID, PSVersion $($PSVersionTable.PSVersion), $PSCommandPath) ---"

# Si la session précédente s'est terminée (redémarrage, fermeture) pendant que le son
# était coupé par le watcher, le déverrouillage n'a jamais eu lieu : on rétablit le son.
$notifications = @()
if (Test-Path $StatePath) {
    $depuis = Get-Content $StatePath -ErrorAction SilentlyContinue
    try {
        if ([AudioEndpointVolume]::GetMute()) {
            [AudioEndpointVolume]::SetMute($false)
            $notifications += "Son rétabli au démarrage : il était resté coupé depuis le verrouillage du $depuis."
            Write-WatcherLog "Son retabli au demarrage (coupe par le watcher depuis $depuis, deverrouillage jamais recu)"
        }
        else {
            Write-WatcherLog "Fichier d'etat trouve (coupe depuis $depuis) mais le son n'est plus muet, rien a faire"
        }
        Remove-Item $StatePath -Force
    }
    catch {
        Write-WatcherLog "ERREUR retablissement du son au demarrage : $($_.Exception.Message)"
    }
}

# Nouvelle version publiée sur GitHub : simple notification (pas de mise à jour sans
# consentement, la mise à jour se fait par -Setup).
$remoteVersion = Get-ScriptVersionFromLines -Lines (Get-RemoteScriptLines)
if ($remoteVersion) {
    try {
        if ([version]$remoteVersion -gt [version]$ScriptVersion) {
            $notifications += "Nouvelle version $remoteVersion disponible (actuelle : $ScriptVersion). Pour mettre à jour : $ScriptFileName -Setup, option I."
        }
    }
    catch {}
}

$watcher = New-Object SessionLockWatcher($LogPath, $StatePath, $SettingsPath, $ScriptVersion)
foreach ($n in $notifications) {
    $watcher.Notify($n)
    Write-Host $n -ForegroundColor Green
}

Write-Host "Surveillance du verrouillage de session active." -ForegroundColor Green
Write-Host "Pour arrêter : clic droit sur l'icône près de l'horloge > Quitter (ou fermer cette fenêtre ; Ctrl+C ne fonctionne pas ici)."
Write-Host "Journal : $LogPath"

[System.Windows.Forms.Application]::Run($watcher)
