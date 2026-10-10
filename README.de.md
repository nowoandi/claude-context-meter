# Claude Context Meter

Ein kleines Widget, das immer im Vordergrund bleibt und zeigt, wie voll das Kontextfenster
jedes laufenden Claude-Chats ist — Claude Code und Cowork nebeneinander — und wie viele
Tokens in den Limitfenstern schon verbraucht sind.

![Das Widget](docs/widget.png)

PowerShell und integriertes WPF, keine zusätzlichen Abhängigkeiten. Chatdaten bleiben lokal.

## Tabs für Claude und Codex

Oben lässt sich zwischen **Claude** (Claude Code und Cowork) und **Codex** wechseln.
Nur die ausgewählte Quelle durchsucht Ordner, liest Protokolle und prüft Prozesse.
Die andere behält ihren Cache im Speicher und liest beim Zurückwechseln ab der gespeicherten
Position weiter. Die Auswahl bleibt nach einem Neustart erhalten. Das pausiert die
Überwachung durch das Widget, nicht die Agenten selbst.

Codex zeigt bis zu sechs Chats mit Aktivität in den letzten drei Stunden, einschließlich
Desktop und CLI. Es sind zuletzt aktive Chats, keine bestätigte Liste offener Fenster.
Titel stammen aus `%USERPROFILE%\.codex\session_index.jsonl`, Verbrauch und Kontextgröße
aus `%USERPROFILE%\.codex\sessions\**\*.jsonl`. Ein gesetztes `CODEX_HOME` ersetzt den
Standardpfad. Cache-Tokens sind bereits in `input_tokens` enthalten. Der Prozentwert wird
aktualisiert, sobald Verbrauch im Protokoll steht; bei unbekannter Kontextgröße erscheint `…`.
Ein Klick bringt das Codex-Anwendungsfenster nach vorne.

Unten stehen die gespeicherten Auslastungswerte für die 5-Stunden- und 7-Tage-Limits.
Fehlende, über zwei Stunden alte, bereits zurückgesetzte oder zeitlich abweichende Limits
erscheinen als `—`. Subagenten erhalten keine eigenen Chatzeilen.

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

Die Fußzeile addiert alle Sitzungen samt Subagenten über die beiden Limitfenster. Das
Wochenfenster zählt ab dem wöchentlichen Reset des Kontos, nicht über die letzten sieben
Tage: Tokens von vor dem Reset zählen nirgends mehr. Den Zeitpunkt lernt das Widget selbst —
Claude Code schreibt die genaue Reset-Zeit ins Protokoll, sobald es das Wochenlimit meldet.
Bis eine solche Zeile auftaucht, gleitet das Fenster über die letzten sieben Tage. Eine
Zeile darunter nennt den nächsten Reset.

Wo die App den Planverbrauch notiert hat, steht sein Prozentwert neben der Summe, solange
das Fenster nicht gewechselt hat: fünf Stunden beim kurzen, bis zum nächsten Reset beim
wöchentlichen. Die App notiert ihn nur wenige Male am Tag, deshalb trägt ein Wert, der
älter als eine Viertelstunde ist, seine Uhrzeit.

## Starten

Installiert startet es als **`ClaudeContextMeter.exe`**. Diese Datei trägt Name,
Herausgeber und Symbol und führt das Skript im eigenen Prozess aus, sodass der Task-Manager
einen Prozess *Claude Context Meter* zeigt statt eines namenlosen *Windows PowerShell*. Als
Fensterprogramm öffnet sie keine Konsole. `build.ps1` baut sie aus `launcher\`.

Aus einer einfachen Kopie der Dateien: Doppelklick auf **`Start-ContextMeter.vbs`** oder

```bash
powershell -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ClaudeContextMeter.ps1
```

Die `.vbs` gibt es, weil `powershell.exe` eine Konsolenanwendung ist: Windows gibt ihr ein
Konsolenfenster, und `-WindowStyle Hidden` versteckt es erst, *nachdem* es existiert —
daher das schwarze Aufblitzen bei jedem Start. Die `.vbs` erzeugt sie von vornherein versteckt.

Das Widget lässt sich mit der Maus verschieben und merkt sich, wohin. Das `✕` blendet es
aus; es läuft weiter und kommt über das Symbol im Infobereich zurück. Wirklich beendet wird
es nur mit **Beenden** in dessen Menü. Startet man es erneut, während es ausgeblendet ist,
kommt einfach das Fenster zurück — eine zweite Kopie entsteht nie.

## Einstellungen

![Das Menü](docs/menu.png)

Klick auf das Zahnrad, Rechtsklick auf das Widget oder Rechtsklick auf das Symbol im
Infobereich — überall dieselben Einstellungen. Ein Doppelklick auf das Symbol zeigt oder
verbirgt das Fenster.

- **Bei der Anmeldung starten** — ein Eintrag im gewöhnlichen Windows-Autostart (dem
  `Run`-Schlüssel Ihres Kontos). Damit steht das Widget im Task-Manager unter **Autostart
  von Apps** mit seinem Symbol und lässt sich auch dort abschalten. Der Haken wird bei jedem
  Öffnen des Menüs neu gelesen und beachtet diesen Schalter, sodass beide nie widersprechen.
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

Der Befehl des Eintrags wird aus dem tatsächlichen Ort des Programms gebaut und ein
veralteter Pfad beim nächsten Start repariert; ein Verschieben des Ordners bricht den
Autostart nicht.

Bis 1.3.1 war der Autostart eine geplante Aufgabe, anfangs, damit sie das Widget zusätzlich
alle 15 Minuten neu starten konnte. Diese Wiederholung fiel weg — ein Neustart im Takt
verbirgt den Fehler, der das Widget umgebracht hat —, und danach tat die Aufgabe genau das,
was ein `Run`-Eintrag tut, nur unsichtbar unter Autostart von Apps. 1.3.2 ersetzt sie beim
ersten Start durch den `Run`-Eintrag: erst wird der Eintrag geschrieben, erst danach die
Aufgabe entfernt.

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
