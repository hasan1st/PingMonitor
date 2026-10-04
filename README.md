# PingMonitor

A lightweight desktop utility for continuous network availability monitoring. Add hosts, watch real-time latency, and track packet loss — all from a single window.

---

## Quick Start

1. Launch `PingMonitor.ps1` from PowerShell 5.1+.
2. Type a hostname or IP address in the input field.
3. Press **Enter** or click **Add monitor**.

![Screenshot: Main window with a few monitors added](screenshots/main-window.png)

---

## Views

Toggle between views with the **Table / Cards** button on the toolbar or press **F8**.

### Card View

Each monitor is displayed as a card showing:

- **Status accent bar** — color reflects current latency or failure state.
- **Hostname and resolved IP**.
- **Current latency** in milliseconds.
- **Average latency** across recent samples.
- **Latency graph** — bar chart of recent ping results. Hover a bar for details.
- **Min / Drop / Max** statistics.

![Screenshot: Card view with latency graphs](screenshots/card-view.png)

### Table View

A compact tabular layout with sortable-style columns:

| Column | Description |
|--------|-------------|
| Status | Colored dot indicating current state |
| Host | Hostname or IP |
| IP | Resolved address |
| Latency | Last round-trip time |
| Avg | Average RTT over history window |
| Min | Minimum RTT since last reset |
| Max | Maximum RTT since last reset |
| Drop | Number of timed-out packets |
| History | Colored squares representing recent samples |

Right-click a **column header** to show or hide columns.

![Screenshot: Table view with all columns visible](screenshots/table-view.png)

---

## Monitor Actions

### Per-Monitor (Card View)

Each card has three buttons in the top-right corner:

| Button | Action |
|--------|--------|
| ↻ | Reset statistics and graph |
| ❚❚ / ▶ | Pause or resume monitoring |
| ✖ | Remove the monitor |

### Per-Monitor (Table View)

Right-click any row to access **Reset**, **Pause / Resume**, and **Remove**.

![Screenshot: Row context menu](screenshots/row-context-menu.png)

### Global Actions

The split button on the toolbar provides bulk operations:

- **Clear** — remove all monitors.
- **Reset** — reset statistics on all monitors.
- **Pause / Resume** — pause or resume all monitors at once.

Click the main part of the button to repeat the last action. Click the dropdown arrow to choose a different action.

![Screenshot: Global action split button menu](screenshots/global-actions.png)

---

## Drag and Drop

Reorder monitors by dragging:

- **Card view** — drag a card to a new position. A blue indicator shows the insertion point.
- **Table view** — drag a row by its left edge to reorder.

The order is preserved when saving configuration.

![Screenshot: Drag-and-drop indicator between cards](screenshots/drag-drop.png)

---

## Configuration

### Saving and Loading

| Action | Shortcut |
|--------|----------|
| Save | **F3** or **Ctrl+S** |
| Load | **F2** |

Configuration is stored as a JSON file next to the script (`PingMonitor.json`). It includes the host list, monitoring settings, theme, view mode, and window size.

### Auto-Save

Enable **Auto-save on exit** in the Options dialog to persist changes automatically when closing.

---

## Options

Open with the **Options** button or **Ctrl+,**.

![Screenshot: Options dialog](screenshots/options-dialog.png)

| Setting | Default | Range |
|---------|---------|-------|
| Interval | 4 s | 0 – 3600 seconds |
| Timeout | 1000 ms | 1 – 2 147 483 647 ms |
| Buffer size | 32 bytes | 0 – 65 500 bytes |
| TTL | 128 hops | 1 – 255 |
| History samples | 7 | 0 – 20 |
| Do not fragment | Off | On / Off |
| Theme | System | Light / Dark / System |
| Always on top | Off | On / Off |
| Auto-save on exit | Off | On / Off |

---

## Status Colors

| Color | Meaning |
|-------|---------|
| 🟢 Green | Latency within normal range (≤ 150 ms) |
| 🟡 Amber | Elevated latency (150 – 250 ms) |
| 🔴 Red | High latency (> 250 ms), timeout, or error |
| ⚪ Gray | Paused or waiting for first result |

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **Enter** | Add monitor |
| **Escape** | Clear input field |
| **F2** | Load configuration |
| **F3** / **Ctrl+S** | Save configuration |
| **F4** | Clear all monitors |
| **F8** | Toggle Card / Table view |
| **F9** | Toggle Compact mode |
| **Ctrl+,** | Open Options |

---

## Compact Mode

Press **F9** to hide the toolbar, input bar, and status bar. Useful for keeping a minimal always-on-top monitor strip.

![Screenshot: Compact mode](screenshots/compact-mode.png)

---

## Requirements
* Windows 10 / 11
* PowerShell 5.1 or later
* .NET Framework 4.6.2+ (included with Windows)
* Network access to monitored hosts (ICMP)
