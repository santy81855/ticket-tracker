# Ticket Tracker

A native macOS app that tracks your tickets **and the small actions around them**
that are easy to forget: moving the card on the Kanban board, posting the kickoff
thread, asking your pod for approvals, handing off to QE, merging, and closing out.

It isn't another Kanban board. It answers one question:

> What do I need to do next, what am I waiting on, and what must happen before
> this ticket can move forward?

Everything is stored locally on your Mac. A companion CLI (and optional MCP server)
lets AI coding assistants such as GitHub Copilot read and update the same tracker
while you work.

![Ticket Tracker in the Aurora theme](docs/screenshots/hero.png)

## Features

- **Guided ticket workflow:** every ticket shows its next step, who it's waiting
  on, and a one-click confirmation. QA and no-QA (toggle-only) tickets follow
  different paths automatically.
- **Personal tasks:** track non-ticket to-dos like "Ask Jack about the API
  rollout", with waiting-on and follow-up dates.
- **Message drafts:** kickoff, approval request, and QE handoff messages are
  filled in from your templates, ready to paste into Teams.
- **Reviews:** stand-up summary, end-of-day recap, insights on where time goes,
  and a brag doc for shipped work with impact notes.
- **Releases:** fix versions are calculated from actual merge dates.
- **Workflow editor:** customize steps, owners, paths, and nudges, then test-drive
  a sample ticket before publishing.
- **Built-in terminal and browser:** tabbed terminal and an in-app browser for your
  Jira board, so everything is in one window. Browser and terminal tabs are restored
  on relaunch (terminals reopen in the same folders with fresh shells).
- **File viewer:** open ticket plans and other Markdown, text, PDF or image files
  in browser tabs (⌘O, drag and drop, or type a path). Markdown is rendered and
  refreshes live while the file is edited.
- **Themes:** light, dark (Dracula, Nord, One Dark, Tokyo Night, Catppuccin, Gruvbox,
  Solarized), and animated scenes (Aurora, Gargantua, Rainy window, Snowy cabin,
  and more).
- **AI assistant integration:** Copilot sessions can see your next actions, save MR
  links and testing notes, and remind you of handoffs before moving on.

## Screenshots

### Tickets and next steps

| | |
|---|---|
| ![Classic](docs/screenshots/theme-classic.png) | ![Confirm a step](docs/screenshots/confirm-step.png) |
| ![Message draft](docs/screenshots/message-draft.png) | ![New item](docs/screenshots/new-item.png) |
| ![Follow-ups](docs/screenshots/follow-ups.png) | ![Waiting on others](docs/screenshots/waiting.png) |

### Reviews and releases

| | |
|---|---|
| ![Stand-up summary](docs/screenshots/standup.png) | ![End of day](docs/screenshots/end-of-day.png) |
| ![Insights](docs/screenshots/insights.png) | ![Brag doc](docs/screenshots/brag-doc.png) |
| ![Releases](docs/screenshots/releases.png) | ![Completed](docs/screenshots/completed.png) |

### Workflow editor

| | |
|---|---|
| ![Steps](docs/screenshots/workflow-step.png) | ![Paths](docs/screenshots/workflow-paths.png) |
| ![Test drive](docs/screenshots/workflow-test-drive.png) | |

### Themes

| | | |
|---|---|---|
| ![Aurora](docs/screenshots/theme-aurora.png) | ![Gargantua](docs/screenshots/theme-gargantua.png) | ![Tokyo Night](docs/screenshots/theme-tokyoNight.png) |
| ![Dracula](docs/screenshots/theme-dracula.png) | ![Linen](docs/screenshots/theme-linen.png) | ![Nebula](docs/screenshots/theme-nebula.png) |
| ![Snowy cabin](docs/screenshots/theme-cabin.png) | ![Catppuccin](docs/screenshots/theme-catppuccin.png) | ![Rainy window](docs/screenshots/theme-rain.png) |
| ![Nord](docs/screenshots/theme-nord.png) | ![Bonsai](docs/screenshots/theme-bonsai.png) | ![Night city](docs/screenshots/theme-skyline.png) |

### Settings, reference, and compact layouts

| | |
|---|---|
| ![Appearance settings](docs/screenshots/settings-appearance.png) | ![Work links settings](docs/screenshots/settings-work-links.png) |
| ![Notes](docs/screenshots/notes.png) | ![Links](docs/screenshots/links.png) |
| ![Compact detail](docs/screenshots/compact-aurora.png) | ![Compact list](docs/screenshots/compact-list.png) |

## Requirements

- macOS 14 or later
- Xcode or the Xcode Command Line Tools (Swift 6.1)

## Build and install

```sh
git clone https://github.com/santy81855/ticket-tracker.git
cd ticket-tracker
bash Scripts/build-app.sh --install
open "$HOME/Applications/Ticket Tracker.app"
```

The app is ad-hoc signed for local use. Your data lives in
`~/Library/Application Support/TicketTracker`, with daily backups.

Then open **Settings → Work links** to add your Jira board, GitLab, and Teams
links, and **Settings → People** for your pod and QE.

## Using it with an AI assistant

Open **Settings → Copilot**:

- **Review Copilot setup** adds the tracker instructions to your Copilot CLI
  instructions file (`~/.copilot/copilot-instructions.md`) after you review and
  confirm the change. Choose **Local CLI** or **MCP**.
- **Instructions for your AI assistant** shows the exact text with a **Copy**
  button. Paste it into another assistant's instructions file (for example
  `AGENTS.md`, `CLAUDE.md`, or Cursor rules).

The helper CLI is bundled at
`~/Applications/Ticket Tracker.app/Contents/MacOS/ticket-tracker`. Run it with
`commands` to see every operation and its JSON input.

Your assistant can show you a plan it wrote with
`ticket-tracker open-file /path/to/plan.md` (MCP: `tracker_open_file`), which
opens it in the app's viewer.

## Development

```sh
bash Scripts/swift.sh build
bash Scripts/swift.sh test
python3 Scripts/test-integration.py "$(bash Scripts/swift.sh build --show-bin-path)/ticket-tracker"
```

Screenshots in `docs/screenshots` are generated from synthetic sample data:

```sh
bash Scripts/build-app.sh --ui-validation   # prints the built app path
TICKET_TRACKER_SHOWCASE=1 TICKET_TRACKER_DATA_DIR="$(mktemp -d)" \
  TICKET_TRACKER_UI_OUTPUT="$PWD/docs/screenshots" \
  "<built app>/Contents/MacOS/TicketTracker"
```
