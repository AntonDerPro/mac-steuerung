# Mac Agent – iOS/iPadOS/macOS App

Eine native SwiftUI-App für deinen Mac-Agent mit **Liquid Glass**-Design.

## Features

| Tab | Beschreibung |
|-----|-------------|
| 🖥️ Status | CPU, RAM, GPU, Akku, WLAN, Prozesse – live mit Auto-Refresh |
| 🎵 Musik | Apple Music steuern, Album Art, Lautstärke-Slider |
| 📁 Dateien | Dateibrowser für Downloads, Desktop, iCloud etc. |
| ✨ Agent | KI-gestütztes Verschieben per natürlicher Sprache |
| 💬 AI Chat | Chat mit Gemma4, Qwen3, Phi-3, Granite (lokal via Ollama) |

---

## Voraussetzungen

### Auf dem Mac
- `main.py` muss laufen: `python3 main.py`
- Ollama muss installiert und gestartet sein
- Modelle runterladen: `ollama pull gemma4`
- Mac und iPhone/iPad im **selben WLAN** oder via **Tailscale**

### Xcode
- Xcode 16 oder neuer
- iOS Deployment Target: **iOS 17.0+**
- Kein Backend/Server nötig auf dem iPhone

---

## Xcode Setup

### Schritt 1: Projekt erstellen

1. Xcode öffnen → **Create New Project**
2. Platform: **iOS** (funktioniert auch auf iPad & Mac via Catalyst)
3. Template: **App**
4. Einstellungen:
   - **Product Name**: `MacAgent`
   - **Team**: Dein Apple-Account
   - **Bundle Identifier**: z.B. `de.deinname.macagent`
   - **Interface**: SwiftUI
   - **Language**: Swift
5. Speicherort wählen, Projekt anlegen

### Schritt 2: Dateien einfügen

Die automatisch erstellte `ContentView.swift` und `MacAgentApp.swift` löschen, dann alle `.swift`-Dateien aus diesem Ordner ins Projekt ziehen:

```
MacAgentApp.swift
ContentView.swift
Models.swift
SharedComponents.swift
StatusView.swift
MediaView.swift
FileView.swift
AgentView.swift
ChatView.swift
```

→ Beim Drag & Drop: **"Copy items if needed"** anhaken ✓

### Schritt 3: Info.plist – Lokales Netzwerk erlauben

In Xcode das Projekt auswählen → **Info**-Tab → folgende Keys hinzufügen:

| Key | Value |
|-----|-------|
| `NSAppTransportSecurity` → `NSAllowsArbitraryLoads` | `YES` |
| `NSLocalNetworkUsageDescription` | `Für die Verbindung zum Mac-Agent im Heimnetz.` |
| `NSBonjourServices` | Array → `_http._tcp` |

**Alternativ** die `Info.plist` direkt als XML bearbeiten und einfügen:

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
</dict>
<key>NSLocalNetworkUsageDescription</key>
<string>Für die Verbindung zum Mac-Agent im Heimnetz.</string>
```

### Schritt 4: Signing & Capabilities

1. Projekt → **Signing & Capabilities**
2. **Team** auswählen (dein Apple-ID-Account reicht für TestFlight)
3. Bundle Identifier muss eindeutig sein

### Schritt 5: Bauen & Testen

Im Simulator: IP auf `localhost` oder `127.0.0.1` setzen (falls Mac-Agent lokal).

Auf echtem Gerät:
1. **Einstellungen** (Zahnrad-Tab) → IP-Adresse des Macs eingeben (z.B. `192.168.1.42`)
2. Port bleibt `8765`
3. Mac-Agent muss laufen: `cd mac-agent && python3 main.py`

---

## TestFlight

1. In Xcode: **Product → Archive**
2. Organizer öffnet sich → **Distribute App**
3. **App Store Connect** → **TestFlight Internal Testing**
4. Warte auf Apple-Review (meist 1-2 Std. für interne Tester)
5. TestFlight-App auf iPhone → App installieren

**Tipp**: Für rein privaten Gebrauch ohne TestFlight einfach direkt aufs iPhone deployen über Xcode (kostenloser Apple-Account reicht, 7-Tage-Zertifikat).

---

## Liquid Glass Design

Die App nutzt `.ultraThinMaterial` (iOS 15+) für echtes Liquid Glass:
- Transluzente Karten mit Blur-Hintergrund
- Dynamischer Album-Art-Hintergrund im Musik-Tab
- Animierte Gauge-Ringe für Systemmetriken
- Shimmer-Ladeanimationen
- Dark Mode durchgehend

---

## Netzwerk-Tipp (Tailscale)

Für Zugriff von unterwegs (nicht nur im Heimnetz):
1. Tailscale auf Mac & iPhone installieren
2. Mac-Agent auf `0.0.0.0:8765` lauscht bereits ✓
3. Tailscale-IP des Macs als Host in den Einstellungen eintragen
