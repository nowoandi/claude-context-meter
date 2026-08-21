# Claude Context Meter

Ein kleines Widget, das immer im Vordergrund bleibt und zeigt, wie voll das Kontextfenster
jedes laufenden Claude-Chats ist — Claude Code und Cowork nebeneinander — und wie viele
Tokens in den Limitfenstern schon verbraucht sind.

![Das Widget](docs/widget.png)

Ein einziges PowerShell-Skript. Keine Installation nötig, keine Abhängigkeiten, kein Netz.

## Was eine Zeile sagt

```
CC  Handover 2026-08-13    ███████░░░   63%   1M
```

| Teil | Bedeutung |
|---|---|
| `CC` / `CW` | woher der Chat kommt — Claude Code oder Cowork |
| Titel | der echte Chattitel, so wie ihn die App zeigt |
| Balken | wie voll das Kontextfenster ist — grün, ab 60 % gelb, ab 80 % rot |
| `63 %` | die letzte Anfrage, gemessen an diesem Fenster |
| `1M` | die Größe des Fensters selbst |

Die letzte Spalte wiegt schwerer, als sie aussieht: 80 % von 200k und 80 % von 1M sind sehr
verschiedene Lagen, und ein Prozentwert allein verschweigt, in welcher man steckt.

Zeilen werden nach 30 Minuten Stille blass. Unter dem Mauszeiger stehen Projektpfad, genaue
Tokenzahl, Modell und wann der Chat zuletzt aktiv war. Ein Klick holt das Claude-Fenster
nach vorn und lässt seine Größe in Ruhe — ein maximiertes Fenster bleibt maximiert.

Die Fußzeile addiert alle Sitzungen samt Subagenten über die beiden Limitfenster — 5 Stunden
und 7 Tage. Wo die App den Planverbrauch notiert hat, steht sein Prozentwert daneben.

## Starten

```bash
powershell -STA -NoProfile -ExecutionPolicy Bypass -File ClaudeContextMeter.ps1
```

Besser mit einem Doppelklick auf **`Start-ContextMeter.vbs`**. `powershell.exe` ist eine
Konsolenanwendung, also gibt Windows ihr ein Konsolenfenster, obwohl das Skript nur ein
WPF-Fenster zeigt, und `-WindowStyle Hidden` versteckt diese Konsole erst, *nachdem* es sie
gibt — daher das schwarze Fenster, das bei jedem Start aufblitzt. Die `.vbs` erzeugt sie von
vornherein versteckt, sodass gar nichts erscheint.

Das Widget lässt sich mit der Maus verschieben und merkt sich, wohin. Das `✕` blendet es
aus; es läuft weiter und kommt über das Symbol im Infobereich zurück. Wirklich beendet wird
es nur mit **Beenden** in dessen Menü. Startet man es erneut, während es ausgeblendet ist,
kommt einfach das Fenster zurück — eine zweite Kopie entsteht nie.

## Einstellungen

![Das Menü](docs/menu.png)

Klick auf das Zahnrad, Rechtsklick auf das Widget oder Rechtsklick auf das Symbol im
Infobereich — überall dieselben Einstellungen. Ein Doppelklick auf das Symbol zeigt oder
verbirgt das Fenster.

- **Bei der Anmeldung starten** — legt eine geplante Aufgabe mit Anmelde-Auslöser an, unter
  Ihrem Konto, ohne Administratorrechte. Der Haken wird bei jedem Öffnen des Menüs aus der
  Aufgabenplanung gelesen, damit eine von außen entfernte Aufgabe als *aus* erscheint statt
  als veralteter Haken.
- **Sprache** — Englisch, Deutsch oder Russisch, sofort wirksam.
- **Aktualisierungsrate** — Normal (3 s), Sparsam (10 s) oder Minimal (30 s). Takt und
  vollständiger Neudurchlauf der Ordner werden zusammen gestreckt, denn der Neudurchlauf ist
  die teure Hälfte; nur den Takt zu bremsen behielte die Kosten und verlöre die Frische.
- **Nach Updates suchen** — beim Start eine Anfrage an GitHub, ob es eine neuere Fassung
  gibt. Wenn ja, erscheint ein grüner Pfeil in der Kopfzeile und eine Zeile in beiden Menüs.
  Jeder Fehlschlag — offline, Anfragelimit, keine Veröffentlichung, kein Installer — heißt
  schlicht „kein Update“: eine Versionsprüfung darf den Start niemals verhindern können.
- **Position merken** — standardmäßig an. Die Position wird geschrieben, sobald Sie das
  Fenster loslassen, nicht erst beim Beenden, und gegen den gesamten Desktop geprüft — ein
  Platz auf einem zweiten Monitor übersteht also einen Neustart, auch dort, wo die
  Koordinaten negativ werden.

Das Widget läuft mit der Priorität `BelowNormal` und bekommt den Prozessor damit nur, wenn
ihn sonst niemand will.

Der Befehl der Aufgabe wird aus dem tatsächlichen Ort des Skripts gebaut und ein veralteter
Pfad beim nächsten Start repariert; ein Verschieben des Ordners bricht den Autostart nicht.

Eine Aufgabe statt eines `Run`-Eintrags in der Registrierung, weil ein `Run`-Eintrag bei der
Anmeldung greift und danach nie wieder — und eine Maschine, die wochenlang schläft statt neu
zu starten, sieht ebenso lange keine Anmeldung. Einen wiederholenden Auslöser gibt es
bewusst nicht: ein Widget im Minutentakt neu zu starten verbirgt den Fehler, der es
umgebracht hat, und drängt sich an Tagen auf den Bildschirm, an denen Claude gar nicht läuft.

## Symbol im Infobereich

Das Symbol beantwortet die Frage „läuft es, und wo ist es hin“. Sein Menü trägt dieselben
Einstellungen plus **Anzeigen / Ausblenden** und **Beenden**, und beim Beenden wird es
ordentlich entfernt statt als Geist zurückzubleiben, der erst verschwindet, wenn die Maus
ihn streift.

Windows 11 legt neue Symbole unter den Pfeil `^`. Ziehen Sie es von dort auf die Taskleiste,
wenn es sichtbar bleiben soll — das ist die Entscheidung der Nutzerin oder des Nutzers und
nichts, was ein Programm erzwingen sollte.

## Woher die Zahlen kommen

Alles wird aus Dateien gelesen, die Claude ohnehin lokal schreibt:

| Quelle | Wofür |
|---|---|
| `%USERPROFILE%\.claude\projects\**\*.jsonl` | Mitschriften von Claude Code — Tokenverbrauch |
| `%APPDATA%\Claude\local-agent-mode-sessions` | Mitschriften und Chateinträge von Cowork |
| `%APPDATA%\Claude\claude-code-sessions` | Chattitel von Claude Code |
| `%USERPROFILE%\.claude\sessions` | welche Sitzungen tatsächlich laufen |
| `%APPDATA%\Claude\plan-usage-history.json` | die Prozentwerte des Planverbrauchs |

Von Ihren Chats geht nichts nach außen. Das Widget spricht mit genau einem Host, und nur
wenn **Nach Updates suchen** eingeschaltet ist: `api.github.com`, um dieses Repository nach
einer neueren Veröffentlichung zu fragen. Schalten Sie die Einstellung aus, und es baut
überhaupt keine Netzverbindung auf.

Der einzige Windows-API-Aufruf holt das Claude-Fenster nach vorn, wenn Sie eine Zeile
anklicken.

Den eigenen Zustand legt es in `%LOCALAPPDATA%` ab: Fensterposition, die gelernten
Kontextfenster je Modell, die Sprache und ein Protokoll.

### Wie die Größe des Kontextfensters ermittelt wird

Nirgends auf der Platte steht, auf welchem Kontextfenster ein Chat läuft, also findet das
Widget es selbst heraus. Eine Anfrage über 200k kann es nur auf einem großen Fenster geben —
das gilt als Beweis. Fehlt der, wird die Markierung `[1m]` im Modellnamen geprüft, danach
das, was dieses Modell früher schon getan hat, über Neustarts hinweg gemerkt. Erst wenn es
gar keine Anhaltspunkte gibt, greift eine Annahme.

## Voraussetzungen

Windows mit Windows PowerShell 5.1 — in Windows 10 und 11 enthalten. Sonst nichts.

## Dateien

| Datei | |
|---|---|
| `ClaudeContextMeter.ps1` | das Widget, vollständig |
| `Start-ContextMeter.vbs` | Start ohne Konsolenfenster |
| `ClaudeContextMeter.ico` | Symbol |

[English version](README.md) · [Русская версия](README.ru.md)
