# Calculator Pen – Konzept und Plan

Status: Entwurf, noch nichts implementiert. Ersetzt den Abschnitt "Calculator pen" in [`IDEAS.md`](IDEAS.md).

Ziel: Ein eigener Stift in der Toolbar. Wer damit eine Rechnung schreibt und `=` setzt, bekommt das Ergebnis
dahinter geschrieben, wie im Rechner der iPad-App (Math Notes). Die Rechnung leuchtet kurz auf, drei Punkte
laufen, dann steht das Ergebnis da.

## 1. Entscheidungen

| Thema | Entscheidung | Folge |
| --- | --- | --- |
| Erkennung | On-device, eigenes Core-ML-Modell für Zeichen, feste Grammatik, eigener Parser | Kein Backend, offline, deterministisch, Privacy-Label bleibt "Data Not Collected". Wir brauchen eigene Trainingsdaten (siehe 6). |
| Umfang v1 | Arithmetik **und** Variablen/Gleichungen | Mehr Zeichen (Buchstaben), kleine Algebra-Engine. Arithmetik wird zuerst fertig und ist als Beta nutzbar. |
| Ergebnis | `TextBox`, verknüpft mit den Rechen-Strichen | Neuberechnen bei Änderung, Export, Suche und Lasso kommen ohne Extra-Arbeit. |
| Notation | Englisch: `.` ist Dezimalpunkt, `×` und `÷` (auch `/`, Bruchstrich) | Kein mehrdeutiges "1.000". Siehe 7 für das, was bewusst nicht unterstützt wird. |
| Farbe | Eigene Stiftfarbe, Standard Blau, änderbar | Die Farbe ist nur Optik. Was gerechnet wird, bestimmt das **Tool-Tag** der Striche, nicht die Farbe. |

**Leitplanken:** `Plan.md`, `AGENTS.md`, `docs/PARITY.md` und `docs/PRIVACY.md` schließen "AI features" und Backend aus.
Ein gebündeltes On-device-Modell ist weder Backend noch Dienst, aber die Formulierungen müssen in Phase 0
angepasst werden, sonst widerspricht die Doku dem Code ("no AI features" → "no cloud or account features, one
bundled on-device recognizer for the calculator pen"). `PARITY.md` führt "math assist" aktuell als Out-of-scope.

## 2. Was die Codebasis schon hergibt (Befunde)

- **Striche tragen ein Tool-Tag.** `Stroke.tool` ist ein `InkTool`. Ein neuer Fall `.calculator` trennt Rechen-Striche
  sauber von allem anderen. Das löst "nur Striche des Calculator-Pens gehören zur Rechnung" an der Wurzel.
- **Neue Tools tauchen automatisch auf.** `ToolbarLayout(storedOrder:…)` hängt neue `InkTool`-Fälle ans Ende an,
  auch bei angepasster Leiste. `ToolbarLayoutTests` und `ToolbarLayout.standard` müssen angepasst werden.
- **Kein Zeitstempel pro Sample.** `Sample` hat nur Punkt, Druck, Neigung. `IDEAS.md` geht davon aus, dass Timing
  gespeichert ist; das stimmt nicht. Reihenfolge in `page.strokes` ist chronologisch, das reicht für v1. Zeit
  zwischen zwei Strichen ist zur Laufzeit (Pen-up) bekannt. Falls das Modell Timing braucht, kommt ein optionales
  `Stroke`-Feld nur für Calculator-Striche dazu (abwärtskompatibel).
- **Einstieg am Pen-up.** `NativeCanvas.swift` ruft am Ende `configuration.onStroke(stroke)` (nach dem Muster bei
  `case .pen, .highlighter, .shapes`). Dort hängt sich der Calculator ein, ohne die Zeichen-Pipeline zu ändern.
- **Räumlicher Index existiert.** `SpatialIndex` (Quadtree, `Editing.swift`) für "was liegt neben dem `=`".
- **Text-Objekte können Schriftart.** `TextBox` hat `fontName`, `size`, `color`, `rotation`; Renderer und PDF-Export
  zeichnen sie schon. Ergebnis als `TextBox` kostet keinen neuen Render-Pfad.
- **Undo sind Snapshots** (`history.undo: [NotebookPackage]`). Das Ergebnis muss sich in den Undo-Schritt des `=` einfügen.
- **Dateiformat:** Version 1, optionale Felder sind kompatibel. Ältere App-Versionen lehnen aber einen unbekannten
  `InkTool`-Wert ab (die Seite wäre dort nicht lesbar). Für eine reine Eigennutzung ok; falls andere alte
  Versionen nutzen: Calculator-Striche als `pen` mit Marker-Feld speichern. Entscheidung in Phase 0.

## 3. Ablauf aus Nutzersicht

1. Calculator-Pen in der Toolbar wählen (Tippen auf das gewählte Tool öffnet die Einstellungen, wie bei den anderen).
   Tinte ist standardmäßig blau.
2. Rechnung schreiben, z. B. `12 × 3 + 4 =`.
3. Beim `=`: Die erkannte Rechnung **leuchtet auf** (Glow plus kurzer Lichtstreifen von links nach rechts).
   Das sagt "erkannt" und zeigt gleichzeitig, **welche Striche** zusammengefasst wurden.
4. Hinter dem `=` laufen **drei Punkte** (Lade-Animation) auf der Grundlinie der Schrift.
5. Die Punkte blenden in das Ergebnis über (`40`), in Handschrift-Font, in Stiftfarbe, passend groß.
6. Spätere Rechnungen auf der Seite bleiben unabhängig; Tippen auf ein Ergebnis zeigt, wie gelesen wurde (siehe 8).

Zustände eines Ergebnisses: `pending` (Punkte) → `done` | `uncertain` (kein sicherer Treffer: kein Ergebnis, sondern
ein kleines `?` mit Korrekturmöglichkeit) | `stale` (Eingabe wurde geändert, wird neu berechnet).

## 4. Architektur

```
Pen-up (calculator stroke)
  → CalculatorTrigger     billiger geometrischer Vortest: könnte das ein "=" sein? Sonst Abbruch.
  → Gatherer              welche Striche gehören zur Rechnung (Abschnitt 5)
  → SymbolRecognizer      Segmentieren + Zeichen klassifizieren (Core ML, Abschnitt 6)
  → LayoutAnalyzer        Beziehungen: rechts, hochgestellt, Bruch, Wurzel, Klammer
  → Parser                AST aus Zeichen + Beziehungen, Grammatik als Filter
  → Evaluator / Solver    exakte Arithmetik, Variablen, Gleichungen
  → ConfidenceGate        sicher? sonst "?" statt falschem Ergebnis
  → ResultPlacer          TextBox mit Verknüpfung, Undo-Schritt, Persistenz
```

| Baustein | Ort | Hinweis |
| --- | --- | --- |
| Parser, Evaluator, Solver, Grammatik, Gatherer, LayoutAnalyzer | `Sources/NoteCraftCore/Calculator/` | Reines Swift, mit `swift test` auf macOS testbar. |
| `SymbolRecognizing` (Protokoll) + `FixtureRecognizer` | Core | Tests und Phase 1 laufen ohne Modell auf Ground-Truth-Fixtures. |
| `CoreMLSymbolRecognizer`, Modell `.mlpackage` | `Sources/NoteCraft/` | Nur dünner Wrapper, keine Logik. |
| `CalculatorEngine` (Actor), Debounce, Abbruch | `Sources/NoteCraft/` | Alles Schwere außerhalb des Main-Actors. |
| Glow, Punkte, Ergebnis-Einblendung | `NativeCanvas.swift` / eigene Datei | Core-Animation-Layer im `inkOverlay`, siehe 8. |
| Tool, Farbe, Einstellungen | `Workspace.swift`, `QuickBar.swift`, `Settings.swift`, `Preferences` | Neuer Key `calculatorColorHex`, Standard `InkColor.blue`. |

## 5. Zuordnung: welche Striche gehören zu welcher Rechnung

Das ist die kritischste Funktion neben der Erkennung selbst.

**Kandidaten** sind nur Striche mit `tool == .calculator`, die zu **keiner** bestehenden Berechnung gehören
(`strokeIDs` in einer verknüpften `TextBox`). Normale Stifte, Highlighter, Bilder, Textfelder und bereits gelöste
Rechnungen sind damit von vornherein draußen, egal welche Farbe sie haben.

**Auslöser:** Das `=` am Ende. Es besteht aus zwei kurzen waagerechten Strichen (oder einem durchgehenden Zug).
Gerechnet wird nur, wenn das `=` das **rechteste** Zeichen seiner Zeile ist. Steht rechts davon noch Calculator-Tinte
(z. B. `10 = 2x + 2`), ist es eine Gleichung, kein Auslöser.

**Zusammenfassen** in zwei Durchgängen:

1. *Zeilenband:* Vom `=` nach links Striche einsammeln, die im vertikalen Band der Zeile liegen (Bandhöhe aus der
   medianen Zeichenhöhe). Der erlaubte Abstand zwischen Zeichen ist **adaptiv** (Vielfaches der medianen
   Zeichenbreite und des bisherigen Abstands), nicht ein fester Wert in Punkten, damit große und kleine Schrift
   gleich gut funktionieren.
2. *Struktur:* Striche anhängen, die an einem Strukturzeichen hängen: Zähler und Nenner im horizontalen Umfang eines
   Bruchstrichs, Inhalt unter dem Wurzeldach, Hochgestelltes rechts oben an einem Zeichen. Diese liegen außerhalb des
   Zeilenbands, gehören aber dazu.

**Harte Grenzen:** das Ergebnis-`TextBox` einer früheren Rechnung, bereits gelöste Striche und ein Zeilenabstand
größer als etwa 0.8 Zeilenhöhen. Dadurch gilt in `2+2= 4  3+3=` das `3+3` als eigene Rechnung.

**Mehrdeutigkeit** ("5      2+2="): Es gewinnt die Aufteilung, die sich als gültiger Ausdruck lesen lässt und die
näheren Striche nimmt. Der **Glow zeigt genau die gewählten Striche** – eine falsche Zuordnung ist sofort sichtbar
und über das Korrektur-Popover reparierbar.

**Tests (Core, synthetische Layouts):** mehrere Rechnungen nebeneinander und untereinander, Bruch mit langem Zähler,
Hochgestelltes, Wurzel, Rechnung neben einer fremden Zeichnung, Rechnung direkt neben einem früheren Ergebnis,
große und kleine Schrift in einer Zeile.

## 6. Erkennung: Genauigkeit ist die Kernfrage

**Ehrlich vorweg:** "Keine Fehler" kann kein Erkenner garantieren, auch der von Apple nicht. Allgemeine
Mathe-Erkennung ist weit davon entfernt (die CROHME-Wettbewerbe liegen auf Ausdrucksebene grob bei 50–70 %). Aber
wir lösen ein viel engeres Problem: ein **kleiner, fester Zeichensatz**, Online-Daten (Striche mit Reihenfolge, nicht
Pixel), harte Grammatik. Dort sind sehr hohe Quoten erreichbar. Entscheidend ist, dass ein Fehler **nie still ein
falsches Ergebnis liefert**.

Fünf Schichten, die zusammen die Fehlerrate drücken:

1. **Geschlossenes Alphabet.** v1: `0–9 + − × ÷ / = ( ) . , ^ √ %`, Bruchstrich, Buchstaben `x y` (dann `a b c n`).
   Plus eine Klasse "kein Zeichen" gegen Kritzeleien.
2. **Online-Daten.** Jeder Strich ist schon getrennt, Segmentierung ist nur "welche 1–4 Striche bilden ein Zeichen".
3. **Grammatik als Korrektor.** Mehrere Lesarten pro Zeichen (Beam Search), gewählt wird die beste **gültige** Lesart.
   `1 7` vs. `1 + 7` oder `5` vs. `S` werden durch den Kontext oft entschieden.
4. **Konfidenz-Schranke.** Ist die beste Lesart nicht klar besser als die zweitbeste oder gibt es keine gültige
   Lesart, wird **nichts gerechnet**: `?` statt falschem Ergebnis. Lieber eine Rückfrage als eine falsche Zahl.
5. **Sichtbar und korrigierbar.** Tippen auf das Ergebnis zeigt die gelesene Rechnung gesetzt (z. B. `12 × 3 + 4`),
   mit Alternativen und Tastatur-Korrektur. Eine Korrektur ersetzt das Ergebnis und wird (lokal) als Trainingsbeispiel
   gemerkt.

**Messbare Ziele** (Zielwerte, in Phase 2 am echten Korpus zu prüfen, keine Zusage):
Symbolebene ≥ 99.5 %; Arithmetik-Ausdrücke ≥ 98 % bei fremder Schrift, ≥ 99.5 % bei der eigenen Schrift nach
Personalisierung; falsches Ergebnis ohne `?` < 0.5 % der Rechnungen.
Release erst, wenn der Benchmark im CI diese Schwellen hält.

**Modell:** Kleiner Symbol-Klassifikator auf Strich-Sequenzen (um 64 resampelte Punkte pro Zeichen, normalisiert, dazu
Größe und Position relativ zur Zeile; nötig für `.` vs. `0` vs. `o`, `-` vs. Bruchstrich, `1` vs. `l`), eventuell mit
kleinem Raster-Zweig. Größenordnung: unter 1 MB, wenige Millisekunden. Segmentierung per DP/Beam über
zeitlich geordnete Striche. Ein End-to-End-Modell (Striche → LaTeX) ist flexibler, aber schlechter zu begrenzen und
größer; es kommt nur in Betracht, falls der Umfang später in Richtung Integrale/Grenzwerte wächst.

**Apples `PKStrokeRecognizer` (WWDC26, iOS 27):** Text-Erkennung on-device, aber Mathe wird in der Session nicht
erwähnt, es gibt keine Konfidenz, keine Alternativen pro Strich, und die App unterstützt ab iOS 17. Kein Fundament,
höchstens ein Test in Phase 0 als zweite Meinung für Ziffern.

**Trainingsdaten:** Der größte Online-Datensatz (Google MathWriting) steht unter **CC BY-NC-SA 4.0** (nicht
kommerziell, Share-Alike). Ein darauf trainiertes Modell in die App zu packen ist ein Lizenzrisiko, sobald die App
kommerziell wird. CROHME ist Forschungsdaten. Plan: **eigener Korpus** mit einem **Trainer-Bildschirm** in der App
(Zeichen und Ausdrücke mit Soll-Text schreiben, lokal als JSON speichern), von dir und weiteren Schreibern, dazu
Augmentierung (Neigung, Jitter, Tempo). Größenordnung grob 10–20 Tausend Zeichen von 15–30 Schreibern; das ist eine
Schätzung und wird an der Lernkurve geprüft. Training mit PyTorch in `scripts/` (außerhalb der App), Export mit
`coremltools`, Skript und Korpus-Format dokumentiert und deterministisch wie `scripts/catalog.py`.

**Personalisierung (Phase 4):** Bestätigte oder korrigierte Zeichen werden als Beispiele deiner Schrift gespeichert;
bei unsicherer Klassifikation zieht ein Nächste-Nachbarn-Vergleich gegen diese Beispiele nach. Das ist der
wirksamste Hebel Richtung "praktisch fehlerfrei" für den eigenen Gebrauch.

## 7. Rechnen und Notation

**Exakte Arithmetik**, nicht `Double`: rationale Zahlen/`Decimal`, damit `0.1 + 0.2 = 0.3`. Weder `NSExpression`
(Abstürze bei ungültiger Eingabe, Gleitkomma) noch Fremdbibliotheken. Eigener Parser mit Rekursion/Precedence.

- Punkt-vor-Strich, Klammern, unäres Minus, Potenz rechtsassoziativ, Wurzel, Bruch, implizite Multiplikation
  (`2(3+4)`, `2x`).
- **Prozent** wie der iPad-Rechner: `50 + 10%` = 55 (Prozent vom linken Operanden). Verhalten wird mit Tests festgenagelt.
- Division durch 0, Überlauf, Unendliches: kein Ergebnis, sondern kleine Meldung ("undefined").
- **Ausgabe:** Punkt als Dezimaltrenner, bis 10 gültige Stellen, `≈` bei gerundeten Werten (Tippen zeigt den exakten
  Bruch, z. B. `1/3`).

**Notation (englisch):** `.` ist immer der Dezimalpunkt, also ist `1.000` immer 1. Ein Komma ist nur als
Tausendertrenner erlaubt, wenn genau drei Ziffern folgen (`1,000` = 1000); in jeder anderen Stellung (z. B. `1,5`)
ist es nicht lesbar und löst die Konfidenz-Schranke aus, mit dem Vorschlag `1.5` im Korrektur-Popover.
Absichtlich **nicht** in v1: `:` als Division (Verhältnis-Mehrdeutigkeit), `·` als Malpunkt (kollidiert mit dem
Dezimalpunkt, Unterschied nur durch Höhe), `,` als Dezimaltrenner. Das kann später eine Einstellung werden.

**Das kleine `x`:** Zwischen zwei Operanden (`3 x 4`) gilt es als Mal, sonst als Variable (`2x + 2`). Wo beides
passt, wird die Lesart markiert (im Popover sichtbar), nicht geraten. Ein Kreuz-`×` (symmetrisch, kleiner, auf
Mittelhöhe) und ein Buchstaben-`x` (Grundlinie) sind getrennte Klassen im Modell.

**Variablen und Gleichungen (Phase 3b/3c):**
- *Definition:* `x = 5` ohne Auslöser am Ende speichert `x` für diese Seite (nur für Rechnungen nach/unter der Definition).
- *Auflösen:* `10 = 2x + 2`, danach `x =` löst nach `x`. Kontext sind Gleichungen **auf derselben Seite**, die `x`
  enthalten; die nächstgelegene davor gewinnt, mehrere eindeutige bilden ein Gleichungssystem.
- *Engine:* nur ein Unbekannter bis Grad 2 in geschlossener Form (linear, quadratisch) und lineare Systeme per
  Gauß mit rationalen Zahlen. **Kein** vollständiges CAS. Integrale, Grenzwerte, Summen, Matrizen sind nicht Teil von v1.
  Sie würden eine eigene Engine und deutlich mehr Erkennungs-Risiko bedeuten.

## 8. Oberfläche und Animation

**Toolbar:** neues Tool "Calculator" (Symbol z. B. `plus.forwardslash.minus`, Name noch offen). Quick Bar zeigt
Farben des Calculator-Pens, Standard Blau. Einstellungen beim erneuten Tippen: Farbe, Stärke, "Rechnung nach Änderung
neu berechnen", Bestätigungs-Anzeige.

**Glow beim Erkennen:** `CAShapeLayer` aus den Umrissen der gewählten Striche, Farbe = Stiftfarbe, Schatten-Radius
0 → ~12 pt → 0 in 0.5–0.7 s, dazu `CAGradientLayer` als Maske für den Lichtstreifen. Läuft im `inkOverlay`, liegt in
Seitenkoordinaten (folgt Zoom und Scrollen von selbst), **verändert weder Kacheln noch Seitenmodell** und löst keine
SwiftUI-Zustandsänderung pro Frame aus. Mit "Bewegung reduzieren" nur ein weiches Ein- und Ausblenden.

**Drei Punkte:** drei `CALayer` mit versetzter Skalierung/Deckkraft (`CAKeyframeAnimation`), an der Grundlinie rechts
vom `=`. Weil das Modell auf dem Gerät in Millisekunden antwortet, bekommen die Punkte eine **Mindestanzeigezeit**
(etwa 0.4–0.6 s), sonst blitzen sie nur auf. Feinabstimmung am echten iPad.

**Ergebnis:** Überblendung der Punkte in den Text, kurzes Aufdecken von links nach rechts. Schrift: ein
mitgelieferter oder System-Handschrift-Font; Größe aus der medianen Ziffernhöhe der eigenen Schrift, Grundlinie aus
der des `=`. Später optional "in deiner eigenen Schrift" (Ziffern aus deinen Strichen wiederverwenden).

**Unsicher:** Kein Glow-Erfolg, sondern ein weiches orangenes Pulsieren der Striche und ein `?` an der
Ergebnis-Stelle. Tippen öffnet das Korrektur-Popover.

**Korrektur-Popover (Tippen auf Ergebnis oder `?`):** gelesene Rechnung gesetzt, bis zu 3 Alternativen, Textfeld zum
Korrigieren, "Neu lesen", "Ergebnis löschen". Das macht aus einem Fehlschlag einen Tipp statt eines unbrauchbaren
Features.

**Undo:** Das Ergebnis wird in den Undo-Schritt des `=` eingefügt (ein Undo entfernt `=` und Ergebnis). Kommt das Ergebnis
erst, nachdem schon weitergezeichnet wurde, ist es ein eigener Schritt. Ein laufender Rechenauftrag wird bei Undo
abgebrochen.

## 9. Datenmodell

- `InkTool.calculator` (neuer Fall); `Stroke.tool == .calculator`, Farbe frei wählbar.
- `TextBox.calculation: CalculationLink?` (optional, fehlt in alten Dateien): `strokeIDs`, kanonischer Ausdruck
  (z. B. `12*3+4`), `kind` (`result` | `definition` | `equation`), `state`, `recognizerVersion`.
- Beim Öffnen wird **nichts neu gerechnet**; gespeicherte Ergebnisse bleiben, auch wenn sich das Modell ändert.
  `recognizerVersion` erlaubt ein bewusstes "Neu lesen".
- **Randfälle:** Eingabe-Striche radiert oder verschoben → Ergebnis wird `stale`, neu berechnet oder entfernt;
  Lasso verschiebt nur Striche oder nur das Ergebnis → Verknüpfung prüfen und Position nachziehen; Kopieren in
  Elements/andere Seite → Verknüpfung bleibt nur, wenn Striche und Ergebnis zusammen kopiert werden.
- `docs/FORMAT.md` bekommt die neuen optionalen Felder; Tests für Round-Trip und Alt-Dateien.

## 10. Performance (laut CLAUDE.md Pflicht)

- Beim Schreiben läuft **nichts** außer dem billigen Vortest am Pen-up; die Zeichen-Pipeline bleibt unberührt.
  Voll erkannt wird nur, wenn der letzte Strich wie das Ende eines `=` aussieht.
- Kandidaten kommen aus einem Index der Calculator-Striche der Seite plus `SpatialIndex`-Abfrage um das `=`; nie
  O(n·m) über die Seite. Inferenz und Parsen im Actor, Ergebnis per `await` zurück auf den Main-Actor.
- Neuer Calculator-Strich innerhalb der Wartezeit (~0.3 s) bricht einen laufenden Versuch ab (der Nutzer schreibt noch).
- **Budgets:** Auslöser → Glow < 50 ms; Auslöser → Ergebnis p95 < 400 ms auf einem aktuellen iPad (harter Timeout 4 s
  → `?`). Gemessen mit einer vollen Seite (≥ 1600 Striche, 20 Rechnungen), analog `ScribblePerformanceTests`.

## 11. Tests

- **Core (`swift test`):** Parser/Evaluator-Tabelle mit hunderten Fällen (Precedence, Prozent, Division durch 0,
  große Zahlen, Notation, Mehrdeutigkeiten), Gatherer-Layouts (Abschnitt 5), Solver (linear, quadratisch, Systeme),
  Round-Trip der neuen Felder.
- **Erkennungs-Benchmark:** Gold-Korpus (Striche + Soll-Text) als Fixtures; Test schlägt unter den Schwellen aus
  Abschnitt 6 fehl. Der Korpus wächst über die "Falsch gelesen"-Meldung im Popover (lokal, nichts verlässt das Gerät).
- **App/UI:** Tool in der Leiste, Standardfarbe Blau, Farbwechsel bleibt erhalten, Ergebnis erscheint, Undo.
- **Performance:** volle Seite, siehe 10.
- **Auf dem iPad (du):** Gefühl von Glow, Punkten und Timing, echte Handschrift, Pencil. Wie bei der Tinte lässt sich das
  hier nur synthetisch prüfen; die Abnahme machst du am Gerät.

## 12. Phasen

| Phase | Inhalt | Fertig, wenn |
| --- | --- | --- |
| 0 – Klärung (klein) | Doku-Leitplanken anpassen, Format-Kompatibilität entscheiden, `PKStrokeRecognizer`-Test auf Ziffern, Daten-Plan | Entscheidungen im Repo festgehalten |
| 1 – Gerüst ohne Modell (mittel) | Tool + Farbe + Einstellungen, `=`-Vortest, Gatherer, Parser/Evaluator für Arithmetik, `TextBox`-Verknüpfung, Glow + Punkte, Popover mit Tastatur-Eingabe, `FixtureRecognizer` | Kompletter Ablauf läuft auf Fixtures; Tests grün |
| 2 – Modell v1 (groß) | Trainer-Bildschirm, Korpus, Trainings-Skript, Core-ML-Modell für Ziffern/Operatoren, Segmentierung, Konfidenz-Schranke | Benchmark-Schwellen erreicht; **Beta möglich** |
| 3 – Struktur und Algebra (groß) | 3a Brüche, Potenzen, Wurzeln, Klammern, Prozent · 3b Variablen, Definitionen · 3c Gleichungen auflösen, Systeme | Je Teil eigener Benchmark-Block grün |
| 4 – Feinschliff (mittel) | Personalisierung, Neuberechnen bei Änderung, Randfälle (Lasso, Elements), Split View/Slide Over | Auf dem iPad abgenommen |

Jede Phase wird in kleinen Conventional-Commits geliefert (`feat:`, `test:`).

## 13. Risiken

- **Genauigkeit** bleibt das Hauptrisiko. Gegenmittel: Schicht 3–5 aus Abschnitt 6; Release nur über Benchmark.
- **Trainingsdaten:** Menge, Vielfalt der Schreiber und Lizenz. Eigener Korpus kostet Zeit, ist aber lizenzsauber.
- **Verwechslungspaare:** `1/7/l`, `5/S`, `0/o/.`, `-`/Bruchstrich, `÷`/`+`, `x` als Mal oder Variable, `,` vs. `.`.
- **Zuordnung:** Rechnungen dicht beieinander; durch Glow sichtbar, durch Popover korrigierbar.
- **Format-Kompatibilität** mit älteren App-Versionen (Abschnitt 2).
- **Mehrere Fenster / Split View:** Overlays und Engine-Zustand müssen pro Fenster/Größe funktionieren; siehe offene
  iPad-Punkte in `CLAUDE.md`.
- **Ältere iPads:** Latenz-Budget auf dem schwächsten unterstützten Gerät (iOS 17) prüfen.

## 14. Noch offen

1. Wer schreibt Trainingsdaten? Du allein (ca. 30–45 min) reicht für den Anfang; für andere Schriften bräuchten wir
   weitere Personen.
2. Soll die App kommerziell werden? Das entscheidet, ob Fremd-Datensätze je in Frage kommen.
3. Name und Symbol des Tools in der Toolbar.
4. Undo-Verhalten (Abschnitt 8) und Mindestzeit der Punkte nach dem ersten Test am iPad bestätigen.
5. Soll das Kreuz-`×` in v1 Pflicht sein (also Buchstaben-`x` nie als Mal akzeptiert)? Das würde die `x`-Mehrdeutigkeit
   ganz entfernen, kostet aber Komfort.
