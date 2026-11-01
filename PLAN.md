# Ticket Tracker: Product and Implementation Plan

**Status:** Version 0.3.1 installed and validated. Native app and organization-permitted CLI integration are ready; MCP permissions are unchanged.
**Date:** October 29, 2026.
**Project directory:** `~/Documents/ticket-tracker`.
**Working name:** Ticket Tracker.

This document records the approved product behavior, technical approach,
implementation sequence, and acceptance criteria. Implementation was approved
on October 29, 2026, including the clarification that QA fixes stay under QA.
Changes to your existing Copilot configuration still require explicit review
and confirmation. Implementation-specific choices are recorded in section 16.

## 1. What we are building

A small, personal macOS application that answers:

> What do I need to do next, what am I waiting on, and what must happen before
> this ticket can move forward?

It is not a replacement for Jira, GitLab, or Teams, and it is not another Kanban
board. It tracks the actions surrounding your tickets, including the small
handoffs that are easy to forget.

The desktop application and Copilot sessions will read and update the same
persistent local records. You can start work in either interface and continue
in the other without copying state between them.

### Confirmed needs

- Tickets live in Jira; merge requests live in GitLab; communication is in Teams.
- Starting implementation involves both moving the Jira ticket and posting a
  kickoff thread in a particular Teams channel.
- Requesting pod approvals involves posting MR links in that thread and tagging
  the team.
- After approval, QA tickets move to `Validate / merge`, followed by a Teams
  handoff to the QE containing testing information.
- QA findings and requested changes are addressed while the ticket remains
  under QA. They do not require moving Jira back to implementation.
- The QE completes QA and moves the Jira ticket to `Ready to deploy`.
- You then merge the MRs and move the Jira ticket to `Done`.
- Some tickets do not require QA and go from implementation to approvals,
  merging, and Done.
- Ordinary tasks, such as asking someone for an update, must also be trackable
  without pretending they are MR-based tickets.
- You do not want to start a development server whenever you use the tool.
- Your existing ticket-workflow starter prompt should continue to work.
- New Copilot sessions should discover the tracker, recover ticket context,
  update appropriate records, and remind you about prerequisites.

### Design principles

1. **Actions are distinct from status.** Advancing a milestone must not silently
   complete a missed Jira update or Teams message.
2. **One shared record.** The app and Copilot use the same domain rules and data.
3. **Low ceremony.** Show the next useful action instead of a large project
   management interface.
4. **No invented completion.** A drafted message is not a posted message;
   implementation finished is not approval received.
5. **Explicit uncertainty.** Distinguish user-reported external state from
   independently verified state.
6. **Local-first.** No tracker account, hosted backend, paid service, or new AI
   subscription is required for the proposed first version.

## 2. First-version scope

| Included in the first version | Deliberately excluded |
| --- | --- |
| Installed macOS app with menu-bar access and a main window | Browser-hosted app or manually started server |
| Ticket records and simple non-ticket tasks | Team-wide boards, assignments, and reporting |
| Two built-in playbooks: QA and no QA | General-purpose workflow builder |
| Next actions, waiting states, follow-up dates, and reminders | Time tracking, sprints, and project planning |
| Saved Jira, GitLab, and Teams links | Automatically scraping the websites |
| Editable message drafts and clipboard helpers | Posting Teams messages automatically |
| Shared local persistence and change history | Cloud sync or multiple-computer synchronization |
| Local MCP tools and persistent Copilot CLI instructions | Automatically integrating every Copilot surface |
| Workflow prerequisite checks | Preventing independent actions taken directly in Jira/GitLab |
| Export, backup, and a tested recovery procedure | App Store release and automatic update infrastructure |

Copilot integration is part of the first-version completion criteria, not a
future optional feature. Direct Jira/GitLab/Teams API integrations are deferred.

The tracker itself will not call an AI model. Copilot remains the assistant you
already use, connected to the tracker through tools.

## 3. Everyday experience

### 3.1 First launch

The app opens normally from an installed `.app` bundle. Setup asks for only:

- The usual Jira base URL and GitLab host, used for links and identity.
- The Teams channel link used for kickoff posts.
- A default pod/team label and QE contact label for message drafts.
- Whether to enable launch at login and macOS notifications.

Contact labels are editable text, not a promise of resolved Teams identities.
Changing the QE for an individual ticket must be easy.

No Jira, GitLab, or Teams credentials are requested in this version. Setup for
Copilot is a separate, explicit action with a preview of the proposed changes.
The tracker remains usable manually if organizational policy blocks local MCP.

### 3.2 Main window

Use a compact list-and-detail layout with these views:

| View | Contents |
| --- | --- |
| Next actions | Tickets with an actionable next step, plus ordinary tasks |
| Waiting | Tickets waiting for approvals, QA, or an external answer |
| Follow-ups | Dated follow-ups, with overdue and today clearly identified |
| All items | Searchable active items and an archive of completed items |

A ticket can have both an outstanding action and an external wait. For example,
waiting for approval must not hide a forgotten kickoff message. These are
independent facts, not mutually exclusive Kanban columns.

Default ordering is overdue follow-ups, today's follow-ups, then other active
actions. Waiting alone does not make an item overdue. There is no opaque
priority score.

Example:

```text
NEXT ACTIONS

PROJ-123  Fix login error
          Next: Post the kickoff thread in Teams
          [Open channel] [Copy draft] [Confirm posted]

PROJ-456  Update checkout
          Next: Request pod approvals
          [Open thread] [Copy draft] [Confirm requested]

Ask Jack about the API changes
          Follow up today
          [Complete] [Reschedule]
```

### 3.3 Ticket details

Each ticket shows:

- Jira key, title, and link.
- QA requirement: `Undecided`, `Required`, or `Not required`.
- One or more GitLab MR links.
- The saved Teams thread link.
- Testing notes and relevant handoff context.
- Its primary next action and any other outstanding required actions.
- Waiting information and an optional follow-up date.
- A compact checklist and chronological change history.

The main controls should be concrete: `Open Jira`, `Copy approval request`,
`Confirm posted`, `Record approvals`, and `Record merged`. Avoid a generic
`Next` button that silently completes several unrelated actions.

Related steps can appear together in one handoff panel. They still retain
separate completion records, so completing one does not imply the others.

### 3.4 Adding a ticket or task

For a ticket, paste a Jira URL or provide its host and key, add a title, and
select the QA requirement if known. Without API integration, the app cannot
fetch the Jira title or description automatically.

Copilot can create the same record using the ticket details in your starter
prompt. Repeating creation for the same Jira host/key must return the existing
record rather than create a duplicate.

A non-ticket task needs only a title. Notes, a relevant link, and a due or
follow-up date are optional. Its lifecycle is simply open, optionally waiting
or deferred, then complete; no MR or QA fields are required.

### 3.5 Starting to track a ticket already in progress

Provide a short catch-up checklist so you can record actions that already
happened. Each completion is explicit and labeled as reported existing state.

Do not infer that every earlier action happened merely because you select a
later milestone. A ticket already under review can still have an unresolved
kickoff-thread action.

## 4. Concrete workflow rules

The following action names are proposed identifiers, not Jira API transitions.
In version one, external work happens in the existing platforms and is then
confirmed in the tracker.

### 4.1 Standard QA path

| Step | Action | Performed by | Tracker behavior |
| --- | --- | --- | --- |
| 1 | Move Jira to `Implementation in progress` | You | Keep an action open until the move is confirmed |
| 2 | Post kickoff thread in the configured Teams channel | You | Offer a draft; save the resulting thread URL |
| 3 | Complete implementation and prepare MRs | You and Copilot | Record implementation completion, MR links, and available testing notes |
| 4 | Post MR links in the thread and tag the pod for approval | You | Offer an approval-request draft; record that it was actually posted |
| 5 | Receive the required pod approvals | Other developers | Wait until approval is explicitly recorded for every relevant MR |
| 6 | Move Jira to `Validate / merge` | You | Keep the Jira action separate from the Teams handoff |
| 7 | Post testing information and tag the QE in the existing thread | You | Require testing information or an explicit explanation of why none applies |
| 8 | Complete QA and move Jira to `Ready to deploy` | QE | Wait for confirmation that QA passed and the board move occurred |
| 9 | Merge the relevant MRs | You | Track merge confirmation per MR; partial merging is not complete |
| 10 | Move Jira to `Done` | You | Close the ticket only after all applicable prerequisites are satisfied |

Steps 1 and 2 become visible when work starts. A missed kickoff post should
remain visible without preventing Copilot from helping you write code.

For step 8, QA passing and the Jira move are separate facts even if recorded
together. The tracker must not tell you to perform the QE-owned move as though
it were your normal responsibility.

If the QE finds an issue, step 8 stays open while you fix it and the QE retests.
The ticket remains under QA in `Validate / merge`; neither the app nor Copilot
should request a move back to `Implementation in progress`.

### 4.2 No-QA path

```text
Start implementation
  -> Confirm Jira move and Teams kickoff
  -> Finish implementation
  -> Request pod approvals in the thread
  -> Confirm approvals for all relevant MRs
  -> Merge all relevant MRs
  -> Confirm Jira is Done
```

The `Validate / merge` move, QE handoff, QA wait, and `Ready to deploy` wait
are not required on this path. They are shown as not applicable because of the
selected playbook, not falsely recorded as completed.

The app must not infer that QA is unnecessary from words such as "toggle."
If QA is undecided, the tracker requires a decision before a QA handoff or
merge-readiness check can pass.

### 4.3 Prerequisites and enforcement boundaries

| Requested milestone | Required facts |
| --- | --- |
| Approval request recorded | Implementation complete, relevant MR links present, Teams thread identified, and earlier required communication accounted for |
| Ready for QA | QA required, all current MR approvals recorded, Jira `Validate / merge` move confirmed, QE handoff posted with testing context |
| Ready for QE retest | Requested fix complete, any required renewed MR approvals recorded, and updated testing context posted to the QE in the existing thread; the ticket remains under QA |
| Ready to merge, QA path | Required approvals still apply, QA passed, and Jira `Ready to deploy` move confirmed |
| Ready to merge, no-QA path | QA explicitly not required and required approvals still apply |
| Done | All relevant MRs recorded as merged, Jira Done move confirmed, and applicable outstanding requirements accounted for |

The same guard functions run whether an action comes from the desktop app or
MCP. Checking a milestone is read-only; recording an action rechecks the rules
inside the write transaction.

The tracker enforces its own records, not the external systems. It cannot
prevent a merge made directly in GitLab or prove an approval exists without an
integration. User-reported confirmations must remain visibly labeled as such.

### 4.4 Multiple MRs, rework, and exceptions

- **Multiple MRs:** Keep approval and merge confirmation per MR. Ticket-level
  readiness is derived from all active MRs, not the first one.
- **Known changes after approval:** Adding an MR or recording material
  implementation changes invalidates the relevant current review/QA readiness.
  Keep the old confirmations in history rather than deleting them. Invalidating
  readiness does not revert the ticket's phase or repeat completed Jira moves.
- **Unknown changes:** Without GitLab integration, unseen commits cannot be
  detected. Copilot instructions must record material changes it makes.
- **Developer review changes before QA:** Track further implementation and
  renewed review before the initial QA handoff.
- **QA findings or requested changes:** Keep the ticket under QA, with the
  existing `Validate / merge` move still recorded. Track the finding, fix,
  any required renewed approvals, updated testing notes, and QE retest as
  actions within QA. Use detail labels such as `Fix requested` or `Waiting for
  QE retest`, not a return to the implementation phase. Preserve the kickoff
  and existing Teams thread; post the fix/retest update in that thread.
  Unresolved findings or stale QA confirmation block merge readiness until
  the QE confirms the current changes pass. This loop can repeat without
  requiring another move into `Validate / merge`.
- **Changing the QA decision:** Recalculate applicability and explain the
  consequences. Removing a QA requirement needs your explicit decision; the
  agent must not do this just to satisfy a blocked merge.
- **Out-of-order external actions:** Let you reconcile what actually happened
  without inventing prerequisite completions. Preserve a visible deviation
  and require a human-entered reason for an exception.
- **Exceptions:** A separate desktop-only exception action can waive a
  requirement with a reason. Normal completion controls and MCP tools cannot
  silently skip required steps. The history distinguishes waived from done.
- **Reopening:** A completed ticket can be explicitly reopened. Preserve the
  previous completion cycle and recorded merge facts.

These are narrow behaviors for the two built-in playbooks, not the beginnings
of a user-programmable workflow engine.

## 5. Message drafts, links, and reminders

### 5.1 Three message drafts

Provide editable, deterministic templates for:

1. **Kickoff:** Ticket key/link, a short description, and that implementation
   has started.
2. **Approval request:** Ticket reference, all relevant MR links, and a pod
   mention placeholder.
3. **QA handoff or retest update:** Ticket reference, relevant MR links, QE
   mention placeholder, testing instructions, environment, and any caveats
   supplied for the ticket. For a retest, include the reported issue and fix
   summary when available, using the existing thread.

Missing information is shown as missing, not filled with plausible text.
Do not invent test results, deployment environments, contacts, or approvals.

Copying text does not complete the associated action. You must still post it
and confirm that it was posted.

Plain copied `@name` text is not guaranteed to create a real Teams mention.
The UI must remind you to select the actual person/team mention in Teams.
Saved HTTPS channel/thread links are the baseline; native Teams deep links
are an enhancement only if verified on the target Mac.

### 5.2 Reminder behavior

- Allow an explicit follow-up date/time on a task or external wait.
- Offer simple choices such as later today, tomorrow, or a custom date.
- Show overdue items in the app even if notification permission is denied.
- Notify once per scheduled occurrence, with a way to reschedule.
- Opening a notification selects the relevant item.
- Rescheduling or completing an item cancels its pending reminder.
- Closing the main window keeps the menu-bar process running.
- Launch at login is opt-in and its actual macOS status is visible.

The first version does not promise a permanently running reminder daemon.
When the app is fully quit, MCP can still update records, but newly created or
changed reminders are not scheduled by the desktop process until it next runs.
Previously scheduled macOS notifications may still appear while it is quit.
Reconcile them on launch and explicitly handle stale notifications.

This limitation must be stated in settings and tested. If reminders must remain
fully current while the app is fully quit, a separate background component is
a follow-up design decision, not an implicit feature.

## 6. Copilot integration

### 6.1 Integration contract

Use a local MCP server plus persistent user-level Copilot CLI instructions.

The MCP server exposes structured operations over the same workflow core and
database as the desktop app. It does not manipulate the UI, rewrite arbitrary
files, or expose a general SQL/shell execution tool.

Copilot CLI launches the local server as a subprocess over standard input and
output. You do not need to start a web server or open the tracker window first.
The helper stops when its client closes; it is not an always-on network service.

### 6.2 Starting a new ticket session

Keep your existing general workflow prompt. Add a short tracker-aware section
after reviewing the actual prompt you currently use.

The expected session behavior is:

1. Identify the ticket from the explicit Jira URL/key in your prompt.
2. Find its existing tracker record, or create one from provided details.
3. Read the current snapshot before proposing lifecycle changes.
4. Briefly mention any immediately relevant missed action.
5. Proceed with implementation without repeatedly nagging about unrelated
   steps.
6. Save useful MR links, testing notes, and known implementation changes.
7. Check prerequisites before requesting approvals, handing off to QA or
   returning a fix for retest, declaring merge readiness, or marking the ticket
   done.
8. End a handoff with the next outstanding action or wait clearly stated.

When handling a QA finding, Copilot keeps the ticket in QA and records the
fix/retest actions. Writing a fix must not trigger an instruction to move Jira
back to implementation or repeat the initial board handoff.

Each mutation identifies the item explicitly. Do not rely on one global
"current ticket," which would be unsafe with concurrent sessions.

Session identifiers can be stored as optional references if available through
supported interfaces. The design must not depend on discovering undocumented
Copilot internals or reading private session database files.

### 6.3 Proposed MCP tool surface

Tool names and request schemas will be finalized in implementation; the
following is the intended bounded surface.

| Tool | Purpose |
| --- | --- |
| `tracker_health` | Report helper, schema, and storage readiness without hiding failures |
| `tracker_list_items` | List/search next actions, waiting items, and tasks with bounded results |
| `tracker_get_item` | Return the item, links, current revision, next actions, waits, and unmet prerequisites |
| `tracker_create_item` | Create or find a ticket, or create a general task |
| `tracker_update_details` | Edit allowlisted fields such as notes, links, testing context, and follow-up dates |
| `tracker_add_mr` | Add a relevant MR and apply any required readiness invalidation |
| `tracker_record_action` | Record a named action or confirmation through the workflow rules |
| `tracker_set_completion_time` | Correct an already-completed item's actual finish time with an audited explanation |
| `tracker_check_transition` | Explain whether a named milestone is allowed and what is missing |
| `tracker_get_message_draft` | Render the appropriate message using actual saved information |

There is no `set_status_to_anything`, `mark_everything_done`, or
`ignore_prerequisites` tool. Policy overrides, restore, and workflow-rule
editing are not exposed through MCP.

QA decisions can be recorded when explicitly supplied by you, including in the
starter prompt. Otherwise they stay undecided; the agent must ask before
recording a decision that removes QA requirements.

### 6.4 Safe mutation behavior

- Every mutation validates its input, prerequisites, and expected item revision.
- Use a unique request identifier so retrying the same request does not create
  duplicate history or records.
- Include source information: desktop user action, agent-recorded information,
  or explicit user-reported external confirmation.
- Agent-recorded external confirmations include a concise confirmation note.
  The tracker labels them as reported, not API-verified.
- Do not mark messages posted because they were drafted or copied.
- Do not mark MRs approved or merged because the code is ready.
- Do not treat free-text ticket content as instructions to bypass the workflow.
- On conflict, return the current revision and require a reread; do not
  overwrite another session's changes.
- On an unavailable tracker or failed save, report the failure explicitly.
  Copilot may still help with code, but must not claim the tracker was updated
  or its readiness checks passed.

A caller's assertion that "the user confirmed" is not cryptographic proof.
MCP tool permissions and instruction-following provide the interaction
boundary; actual verification of external events requires future integrations.

### 6.5 Persistent setup for future sessions

After you approve installation:

1. Install the app and bundled helper at a stable path.
2. Preview and add a user-level MCP entry through Copilot's supported setup.
3. Preview and append a clearly delimited tracker section to the effective
   user-level `copilot-instructions.md`, preserving existing instructions.
4. Respect `COPILOT_HOME` if set, instead of assuming `~/.copilot`.
5. Start a new session and verify instruction loading and MCP tool availability.

Illustrative registration command, not something to run before installation:

```sh
copilot mcp add ticket-tracker -- \
  "/Users/<username>/Applications/Ticket Tracker.app/Contents/MacOS/ticket-tracker" \
  mcp
```

Selecting available MCP tools is not the same as granting unrestricted write
permission. Preserve normal Copilot permission prompts and organizational rules.

Do not overwrite existing MCP entries or instruction files, install hooks
without approval, modify unrelated repositories, or enable broad automatic
permissions. User-level integration is proposed so it works across repositories.

These guarantees initially cover Copilot CLI on this Mac. IDE, cloud-agent,
or other-machine support requires separate configuration and is out of scope.

### 6.6 Changing the tracker itself

Distinguish two operations:

- **Using the tracker:** Copilot changes ticket/task data through the MCP tools.
- **Developing the tracker:** In a separately authorized coding task, Copilot
  changes this project's source, runs its tests, and rebuilds the app.

The MCP tools cannot rewrite the application's code or weaken its rules.
The desktop-only exception restriction is an API boundary, not a defense
against another same-user process with direct filesystem access.

## 7. Proposed technical architecture

### 7.1 Recommended default

Build a native macOS app using SwiftUI, with a shared Swift package for the
workflow engine, persistence, and MCP adapter.

| Component | Proposal | Reason |
| --- | --- | --- |
| Desktop UI | SwiftUI main window and `MenuBarExtra` | Native installed experience without a development server |
| Workflow core | Typed Swift models and explicit guard functions | One implementation of behavior for both interfaces |
| Storage | SQLite through GRDB | Transactions, migrations, and concurrent local access |
| Agent interface | Official Swift MCP SDK using stdio | Reuse the same core without a separate language/runtime |
| Notifications | macOS UserNotifications APIs | Native notification behavior |
| Login item | Supported macOS ServiceManagement APIs | No custom shell startup scripts |
| Tests | Swift package tests plus Xcode UI/smoke tests | Validate the rules and actual installed experience |
| Distribution | Locally installed `.app` containing the helper | Normal launches and a stable MCP executable path |

Proposed deployment target: macOS 14 or later. Proposed build requirement:
Swift 6.1 or later with a compatible full Xcode installation. Validate the
actual Mac and pinned dependency versions before committing to this baseline.

Pin tested dependency releases and commit the resolved package versions. Do not
build the product against dependency `main` branches.

This choice favors your current macOS environment and avoids a Node runtime,
browser UI server, or second implementation of workflow rules. A Tauri-based
app would be a reasonable alternative if cross-platform support or a strong
web-stack preference matters more; it is not a parallel first-version effort.

### 7.2 Process layout

```text
Ticket Tracker.app
  Main window + menu bar + reminder reconciliation
                    |
                    v
          Shared workflow/store package
                    |
                    v
       Local SQLite database and history
                    ^
                    |
          Shared workflow/store package
                    ^
                    |
  Bundled ticket-tracker executable, "mcp" mode
                    ^
                    |
          Copilot CLI, through stdio
```

The helper accesses storage directly through the shared package. It does not
need the app process, an HTTP port, or a launch daemon.

A fully quit app therefore does not block Copilot from reading or updating a
ticket. Notification scheduling remains subject to section 5.2.

### 7.3 Proposed source layout

```text
ticket-tracker/
  PLAN.md
  TicketTracker.xcodeproj/
  App/
    Views/
    Notifications/
    Settings/
  Packages/
    TrackerKit/
      Package.swift
      Sources/
        TrackerCore/
        TrackerStore/
        TrackerMCP/
        ticket-tracker/
      Tests/
  Tests/
    UITests/
  Configuration/
    CopilotInstructions.md.template
    MCPSetup.example.json
```

Create these only as implementation requires. The Xcode app target links the
package and bundles its helper. There is no generic plugin system or custom
IPC framework.

### 7.4 Apple developer membership and local installation

The proposed personal, locally built macOS app must not require a paid Apple
Developer Program membership. Xcode is free, and local/ad-hoc signing is the
intended approach for running the app on the Mac where it is built.

This is not an iPhone installation using a short-lived free provisioning
profile. The intended Mac build must not require weekly rebuilding or
reinstallation. Xcode is needed to build or update the app, not to launch it
for everyday use.

App Store distribution and the normal Developer ID signing/notarization path
for distributing an app to other people's Macs require program membership.
Those distribution paths are outside the first-version scope.

Milestone 0 must verify the installed app, bundled helper, notifications, and
login-item behavior using the no-paid-membership setup on the actual Mac.
Managed-device policy may impose separate restrictions. If any proposed
feature cannot work under these constraints, report it and revisit the design;
do not silently introduce a paid membership requirement or bypass protections.

## 8. Persistence, synchronization, and recovery

### 8.1 Locations

Project source and this plan belong in `~/Documents/ticket-tracker`.

The current `Documents` directory is a link into a corporate OneDrive folder.
That is not a suitable location for a live multi-process SQLite database.

Use a local runtime directory instead:

```text
~/Library/Application Support/TicketTracker/
  tracker.sqlite
  tracker.sqlite-wal       # SQLite-managed when present
  tracker.sqlite-shm       # SQLite-managed when present
  Backups/
```

Do not place live databases, personal ticket data, generated drafts, or local
backups in the source repository. Exports go only to a location you explicitly
select, with a warning if it is cloud-synchronized.

### 8.2 Data model

Use ordinary current-state tables plus an append-only application history.
Full event sourcing is unnecessary.

| Record | Main information |
| --- | --- |
| Item | Stable ID, ticket/task type, title, Jira identity where applicable, notes, QA decision, dates, revision |
| MR | Item ID, canonical GitLab URL, review round, approval confirmation, merge confirmation |
| Action record | Named step, review round, applicability, completion/waiver state, source, timestamp, confirmation note |
| Follow-up | Item/action reference, scheduled instant, deferral information, notification identity |
| History event | Actor/source, operation, changed fields, timestamp, reason, request identifier |
| Mutation receipt | Request identifier, request fingerprint, and original result for safe retries |
| Settings/metadata | Contact labels, message templates, playbook/schema version, store identity |

Uniqueness for tickets is based on normalized Jira host and key, not title.
Each MR belongs to a ticket and is unique within it by canonical URL.
Store dates as unambiguous instants and render them in the user's local zone.

Derive next actions and lifecycle labels from the recorded facts. Do not keep
an independently editable status field that can drift from the checklist.
Store the built-in playbook version used by each ticket so a future update
does not silently reinterpret its history.

### 8.3 Concurrent app and agent access

- Enable SQLite foreign keys, WAL mode, and a bounded busy timeout.
- Validate and persist each operation and its history in one transaction.
- Use optimistic item revisions for writes from every interface.
- Use a store-generation identifier so writes based on a pre-restore snapshot
  cannot accidentally target restored records with reused revision numbers.
- Different tickets can be updated independently. Conflicting writes to one
  ticket must produce a visible conflict rather than last-writer-wins loss.
- Check schema compatibility in both processes. An outdated helper must fail
  clearly instead of guessing at a newer database schema.

Do not assume an in-process GRDB observer sees writes from other processes.
For the first version, refresh on activation and use lightweight
`PRAGMA data_version` checks on a persistent connection: approximately once per
second while the main window is visible and every 15 seconds while menu-bar-only.
Own-process writes refresh immediately.

Revisit polling only if measurement shows a meaningful resource problem.
Do not add a background service just for change notifications.

### 8.4 Backup and recovery

- Provide a versioned JSON export for portability and inspection.
- Create consistent SQLite backups using supported backup APIs, not a raw copy
  of the main file while WAL writes may be pending.
- Keep a bounded set of local daily backups, initially seven, plus a
  pre-migration backup.
- Surface backup failures; do not report a backup as successful until complete.
- Provide an explicit, confirmed restore path with preview and a backup of
  the current store.
- Coordinate restore across app/helper connections using a shared maintenance
  lock. If active clients cannot quiesce, refuse and explain which sessions
  must be closed; do not replace a database under active writers.
- Change the store-generation identifier after restore and force clients to
  reread.
- Test export/import and backup/restore with actual histories and multiple MRs,
  not just an empty database.

Never recover from corruption by silently opening a new empty database.
Show the error and the available recovery path.

## 9. Privacy and permissions

- No application telemetry or runtime network requests to third-party services
  are required in version one. Opening a Jira/GitLab/Teams link is user initiated.
- A locally stored record can still leave the machine when returned to Copilot
  as model context. Keep responses relevant and bounded, avoid credentials,
  and follow corporate data-handling rules. "Local-first" does not mean
  "Copilot never transmits this information."
- Store no API tokens in this version. If later integrations require them,
  use macOS Keychain rather than source files or exported ticket data.
- Restrict the runtime directory and database permissions to the current user.
  Do not claim application-level encryption; OS disk encryption is separate.
- Treat ticket descriptions, URLs, and drafts as data, not executable commands
  or instructions. Do not execute arbitrary content from them.
- Validate saved link schemes. Baseline links are HTTPS, not shell commands
  or arbitrary local-file URLs.
- Keep MCP protocol output on stdout and diagnostics on stderr. Avoid dumping
  ticket bodies into diagnostic logs.
- Respect managed-device installation, notification, login-item, and Copilot
  MCP policies. Show disabled capabilities plainly.

The current project directory may synchronize through OneDrive. Do not commit
or export real ticket examples there without checking company policy.

## 10. Implementation milestones

Implementation was approved after the QA rework correction.
Milestones are ordered by dependency, not promised calendar duration.

### Milestone 0: Validate the architecture and installation path

**Deliverables**

- Confirm macOS, Xcode/Swift, local-build signing, and managed-device constraints.
- Pin compatible releases of GRDB and the official Swift MCP SDK.
- Build a minimal native app and bundled stdio helper using the shared package.
- Prove that the installed helper can be launched by Copilot using an absolute
  path, without a development server and with the app fully quit.
- Prove both processes can safely access the same test database.

**Exit criteria**

A minimal health tool works from a fresh Copilot CLI session, the normal app
bundle launches, and local installation works without a paid Apple Developer
Program membership or periodic provisioning-based reinstallation. Verify the
notification and login-item capabilities under the same setup. Investigate
signing requirements rather than disabling corporate protections or relying
on removing quarantine attributes.

If a foundational choice fails, revise this plan before building the full UI.
Any real Copilot configuration change during this spike needs separate approval.

### Milestone 1: Implement the workflow core

**Deliverables**

- Typed ticket/task, MR, action, QA-decision, and confirmation-source models.
- Two versioned built-in playbooks and deterministic next-action calculation.
- Guard functions for approval requests, QA handoff/retest, merge readiness,
  and Done.
- Multiple-MR handling, explicit rework, applicability, and human exceptions.
- Deterministic message rendering with visible missing fields.

**Exit criteria**

Focused unit tests cover both complete paths, missed actions, undecided QA,
partial approvals/merges, QA fix/retest loops that preserve the QA phase and
completed board moves, other rework, and attempted invalid transitions.
No database or UI is needed to validate these rules.

### Milestone 2: Add reliable shared persistence

**Deliverables**

- Schema and migrations, transactional repository operations, and history.
- Duplicate-ticket detection, revision conflicts, and retry idempotency.
- Shared local paths, compatibility checks, backup, and recovery support.
- Cross-process change detection.

**Exit criteria**

Two independent processes can write without lost updates. Restarting either
interface preserves data. Stale writes, interrupted transactions, failed
storage access, and incompatible schema versions produce explicit errors.

### Milestone 3: Build the manual desktop workflow

**Deliverables**

- Main views, search, ticket details, and fast task capture.
- Ticket creation/catch-up, two playbooks, MR tracking, and action confirmation.
- Saved links, editable drafts, copy/open controls, and a history view.
- Rework, human-only exceptions, completion, archive, and reopening.

**Exit criteria**

You can run one QA ticket, one no-QA ticket, and one ordinary follow-up task
end to end through the app without developer tools. External actions are
represented accurately and never completed just by opening a link.

### Milestone 4: Connect Copilot end to end

**Deliverables**

- The bounded MCP tools backed by the same domain/store operations as the app.
- Clear tool errors, bounded context responses, and source-labeled updates.
- Reviewed persistent-instruction template and a small addition to your
  actual ticket starter prompt.
- Explicit setup, configuration backup, and removal instructions.

**Exit criteria**

A new session creates or resumes the correct ticket, saves notes/MRs, sees
desktop changes, reports blockers at handoffs, and cannot bypass guards with
an ordinary status mutation. Another new session recovers the same state
without relying on conversation memory.

Both interfaces remain consistent with concurrent sessions. Repeat the test
with the main window closed and with the application fully quit.

### Milestone 5: Finish daily-use packaging and reminders

**Deliverables**

- Menu-bar access, normal window lifecycle, opt-in login launch, and reminders.
- Reminder reconciliation on external writes, wake, completion, and relaunch.
- Installed bundle and stable helper location, with version diagnostics.
- Working export/restore interface and final local-use instructions.

**Exit criteria**

The app can be used after a normal login without a terminal startup command.
All applicable acceptance scenarios in section 11 pass on the target Mac.
No manual development server, paid tracker service, or hidden daemon is needed.

## 11. Verification and acceptance scenarios

Automate domain and persistence behavior; manually verify OS interactions and
fresh-session Copilot behavior where model/permission behavior is involved.
Do not use brittle assertions about the exact wording of Copilot responses.

| Scenario | Expected result |
| --- | --- |
| Standard QA ticket | Every board update and communication step remains accounted for through Done |
| No-QA ticket | Approval remains mandatory; QA-specific actions are not applicable |
| Undecided QA | Merge/handoff checks explain that a decision is missing |
| Missed kickoff post | It remains actionable even if implementation has progressed |
| Draft copied or link opened | Neither action marks an external step completed |
| Pod approval wait | The item is waiting, with an optional follow-up rather than an arbitrary overdue status |
| Two MRs, one approved | QA/merge readiness stays blocked for the remaining MR |
| Two MRs, one merged | Done stays blocked for the remaining MR |
| QE completes testing but board is unchanged | The missing `Ready to deploy` confirmation remains visible |
| QA finds an issue or requests a change | The ticket remains under QA; fix/retest actions appear without a move back to implementation |
| QA fix is ready for retest | Required renewed approvals and an updated QE message are accounted for; the existing thread and Jira QA move are preserved |
| Material implementation changes after approval | Relevant review/QA readiness is invalidated without reverting the ticket's phase; merge stays blocked until current requirements are satisfied |
| Existing ticket imported mid-flow | Only explicitly reported actions are completed |
| Human exception | Reason and waived state appear in history; MCP cannot invoke the exception route |
| Ordinary task | No ticket, MR, Teams, or QA fields are necessary |
| Repeated creation or mutation | Existing ticket/original result returned without duplicate effects |
| Two sessions update one revision | One succeeds; the stale write conflicts without losing data |
| App and helper restart | Records and outstanding actions survive |
| MCP write with app open | The desktop refreshes without reopening or manual sync |
| New session in another repository | User-level instructions/tools recover the explicitly identified ticket |
| Tracker unavailable | Copilot reports unsaved state, not a successful update |
| Main window closed | Menu-bar access and ordinary reminder handling continue |
| App fully quit | MCP still works; reminder limitations match the documented behavior |
| Notifications denied or a reminder is stale | In-app follow-ups remain correct; no false claim of notification delivery |
| Sleep, wake, or time-zone change | Dates remain correct and reminders reconcile without duplicates |
| Backup/export/restore | Complete records/history recover and stale pre-restore writes are rejected |
| Unsupported schema or damaged database | Clear failure and recovery guidance, never an empty success-shaped fallback |
| macOS login and installed app launch | No terminal command or development server is necessary |

Expected validation tools after the scaffold exists:

- Swift package tests for workflow, persistence, and MCP adapter behavior.
- A subprocess integration harness for stdio MCP and concurrent store access.
- Xcode build and focused UI tests for the macOS app.
- One consistent Swift formatter/lint check using the available toolchain.
- Manual installed-bundle, login-item, notifications, and fresh-session checks.

The exact commands and schemes will be recorded when those targets exist.
Documentation-only review of this plan does not require installing dependencies
or running an application build.

## 12. Risks and explicit limitations

| Risk or limitation | Planned handling |
| --- | --- |
| Maintaining another app could add friction | Action-oriented home screen, few fields, existing links, and agent-assisted updates |
| Manual external confirmations can be forgotten | Keep the action open; use handoff checks and explicit follow-ups |
| External reports can be incorrect | Label sources honestly; do not claim independent verification |
| Rules could become too rigid | Narrow, audited human exceptions and explicit rework |
| Concurrent sessions could overwrite state | Transactions, revision checks, and idempotent operations |
| OneDrive could interfere with live storage | Runtime database outside Documents and the repository |
| SDK/toolchain or managed-device restrictions | Validate installation and MCP feasibility first |
| MCP/configuration or instruction changes might affect other work | Preview changes, preserve existing content, use a small conditional instruction block |
| New Copilot sessions may not have instructions/tools enabled | Verify availability; do not equate configuration with guaranteed model compliance |
| Fully quit app cannot reconcile new reminders | Document the limit; menu-bar/login operation is the normal daily mode |
| Single-Mac storage can be lost | Consistent local backups, explicit export, and tested restore; no implied cloud disaster recovery |

## 13. Decisions for your review

These are proposed defaults, not unanswered prerequisites to writing this plan.
Correct them in review before implementation.

| Decision | Proposed default |
| --- | --- |
| Platform and stack | Native macOS/SwiftUI first; no cross-platform target yet |
| Primary interface | Main action-queue window with lightweight menu-bar access |
| Runtime behavior | Opt-in launch at login; closing the window keeps the app running; no permanent helper daemon |
| Apple membership | No paid membership for the personal local build; paid distribution is outside scope |
| Integration scope | Copilot MCP in version one; direct Jira/GitLab/Teams APIs later |
| QA decision | Explicit choice; leave undecided when your prompt does not specify it |
| No-QA Jira flow | Skip `Validate / merge` and `Ready to deploy`; confirm this matches your actual team practice |
| QA findings and fixes | Confirmed: remain under QA; track fix/retest actions without returning Jira or the local lifecycle phase to implementation |
| Meaning of approval | You confirm that each MR has the approvals your pod requires; do not invent a fixed approval count |
| Exceptions | Desktop-only waiver with a reason, never an agent-accessible bypass |
| Ticket assumption | Initial ticket playbooks are MR-based; ordinary non-ticket tasks are separate |
| Tickets without any MR | If these are common, add a small operational-ticket playbook before implementation rather than pretending they are MR tickets |
| Reminders while fully quit | Accept the documented limitation initially; normal use keeps the menu-bar app running |
| Data handling | Project under Documents as requested; live data local; review company policy for Copilot context and exports |
| Workflow prompt | Preserve yours and add a small tracker section after you share/review its current wording |

Actual Jira URLs, channel/thread links, contact labels, and your starter prompt
are setup inputs. They should not be fabricated or committed as real examples
in the project.

## 14. Next steps and later improvements

### 14.1 Versioned workflow editor

Requested after hands-on use: make the workflow easy to change without editing
Swift code, both when the team's process changes and when another developer
wants to use the app. The user authorized full implementation and replacement
of the installed app; the editor is now implemented in source and under release
validation.

- Provide a visual **Workflows** editor starting from the built-in ticket and
  personal-task playbooks. Allow duplicating a template rather than requiring
  everyone to start from a blank configuration.
- Let a person rename, add, remove, and reorder steps; change board-column
  labels and destination links; specify who moves a ticket from which column
  to which column; configure messages, contacts, required fields,
  confirmations, and dependencies; and choose simple QA/no-QA branches.
  Keep the first editor focused on these concrete needs, not arbitrary scripts
  or a general-purpose automation engine.
- Show a plain-language preview of the next actions for sample QA, no-QA,
  rework, and non-ticket cases before publishing. Detect broken dependencies,
  cycles, unreachable steps, and incomplete settings. Clearly flag changes
  that remove an existing approval, testing, merge, or completion safeguard.
- Save published workflow **versions**. Existing tickets retain the version
  they started with unless the person explicitly migrates them after a preview
  of the step mappings and consequences. Do not silently erase history,
  invalidate real confirmations, or mark new steps completed.
- Let another developer export/import reusable templates independently of
  tickets, personal notes, contacts, and credentials. Keep their Jira board,
  Teams destinations, and team preferences configurable during setup.
- Make the desktop app and CLI read the same published workflow definitions,
  including stable step IDs, version, current next actions, and blockers.
  Copilot must discover the current workflow instead of assuming this team's
  original hard-coded sequence. Provide CLI commands for Copilot to edit and
  publish a workflow when the user explicitly requests it, using the same
  validation, change preview, versioning, conflict detection, and audit trail
  as the desktop. Publishing must not silently migrate existing tickets,
  invent completed facts, or authorize external platform actions.
- Update the generated Copilot instructions so recording progress is part of
  doing the work, not a second manual chore for the user. Copilot should
  automatically save implementation progress, notes, links, and actions it
  successfully performs or verifies. If it actually merges an MR, it should
  record that merge in the tracker without asking the user to confirm the
  same fact again. A direct user report in chat also counts as confirmation;
  do not demand a second checkbox or repeated question.
- Keep Jira column moves explicitly user-confirmed. Never infer that a Teams
  draft was posted, that unknown approvals were received, or that QA passed.
  Record the source/evidence of external facts. Check workflow gates before
  taking external actions; automatic tracker updates are not permission to
  merge or bypass a missing prerequisite. If an already-performed action is
  recorded, preserve and surface any outstanding workflow obligations rather
  than pretending they happened. Keep installed personal instructions
  unchanged until the matching preview update is approved for installation.

Acceptance: a non-programmer can adapt or duplicate a workflow, preview it,
publish it for new tickets, and see identical next-step/guard behavior in the
app and Copilot. Existing in-flight tickets and their audit trails remain safe.
The desktop editor and `workflow` CLI operation use the same validated catalog.

The user's corrected personal template assigns the move from Validate / merge
to Ready to deploy to the developer, not the QE, after required QA passes.
Adding the version date in Jira is part of that move. The exact Jira field,
**Fix Version/s**, must also have its value saved in the tracker before the
step can be completed. Its value represents the Tuesday after the actual
merge day, with the supplied example format `2026.11.3`; do not derive it from
the day an old merge happens to be recorded in the tracker. The user explicitly
confirmed that this move/version assignment occurs **after ticket MRs merge**.
When ticket MRs merge in different release weeks, use the Tuesday strictly
after the **last ticket MR's actual merge date**, excluding workspace MRs.
Tuesday merges use the following Tuesday, in the Mac's local calendar/time zone.
Remove the developer's final Jira Done move: developer work finishes after the
required QA, configured handoff requirements, and every MR merge; the PO owns
any subsequent Jira/business workflow. Existing tickets must not silently
adopt that change. The earlier "not ready to implement" pause was explicitly
superseded by authorization to finish all accumulated changes and replace the
installed build after validation. Refresh only the owned Copilot instruction
block using the existing backup/preservation mechanism.

The main next-action card's completion button must become a more prominent,
full-width primary action with a large accessible click target (at least
44 points high), clear contrast, and tasteful hover/pressed/focus states.
Board links, message drafts, and other secondary controls must not compete
with it. Preserve the completion explanation/confirmation dialog, prerequisite
checks, captured revision, busy state, and minimum-window usability.

After all ticket MRs merge, require a message saying `merged` in the existing
Teams thread before the ticket's workflow is complete. Drafting the message
is not evidence that it was posted.

Distinguish ticket MRs from explicitly classified **workspace MRs**.
Workspace MRs are optional follow-up work: their approval/merge state must not
block ticket completion. Copilot guidance must state this explicitly. Provide
a workspace-MR catch-up filter for merged/unmerged state that also includes
completed tickets, without a two-day cutoff. Recording a later workspace merge
must not reopen the ticket or change its original completion date. Do not guess
an MR's role from its repository name, and preserve real merge facts when a
person changes a classification.

### 14.2 Other possible improvements

Only pursue these after using the first version and identifying real friction:

1. Read-only GitLab integration for actual MR approval and merge state.
2. Read-only Jira integration to verify board-column changes.
3. Explicit, user-approved Jira transitions through an API.
4. Teams integration for message posting and actual mention identities, subject
   to corporate Microsoft permissions.
5. A background reminder component if fully quit operation is necessary.
6. A lightweight operational-ticket playbook if no-MR work needs it.
7. Additional Copilot clients or cross-platform support.

External integrations should preserve the same source/provenance model and
workflow rules. They should replace manual confirmations with verified events,
not introduce another independent copy of the ticket lifecycle.

## 15. Reference material checked for this proposal

Checked October 29, 2026. Recheck supported versions during milestone 0.

- [Copilot CLI MCP configuration](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers):
  local stdio processes, user configuration, setup commands, and policy limits.
- [Copilot CLI custom instructions](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-custom-instructions):
  user-level instruction files, `COPILOT_HOME`, and instruction refresh behavior.
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk):
  server support and stdio transport. Its checked development manifest uses
  Swift tools 6.1; select a tested release rather than assuming README minimums
  and every branch are identical.
- [GRDB](https://github.com/groue/GRDB.swift):
  SQLite persistence, concurrency, migration, and backup facilities. The checked
  README requires Swift 6.1 or later.
- [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra):
  native menu-bar access and window-style presentation.
- [Apple Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html):
  local signing identities and the distinction between signing and
  Apple-issued distribution identities.
- [Apple Developer ID](https://developer.apple.com/developer-id/):
  program membership for Developer ID certificates and notarized distribution
  outside the Mac App Store.

## 16. Implementation choices and local commands

- The native app and helper are Swift Package Manager executable targets in one
  root package. This avoids a hand-maintained Xcode project while retaining
  SwiftUI, shared modules, package tests, and an ordinary installed `.app`.
  Full Xcode is available on the target Mac.
- GRDB is pinned to 7.11.1. The MCP SDK is pinned to 0.12.1 because 0.11.0
  failed Swift 6.3 concurrency checks in its network transport; no dependency
  source or compiler safety checks were patched.
- Current item aggregates (including MR/action records and history) are stored
  transactionally as versioned JSON payloads in indexed SQLite rows. Separate
  metadata, settings, and idempotency tables enforce shared-store behavior.
- Build products and dependency checkouts live in
  `~/Library/Caches/TicketTracker`, outside OneDrive.
- SwiftPM's bare Git caches conflict with the session's inherited
  `safe.bareRepository=explicit`. A command-scoped compatibility setting was
  explicitly approved. `Scripts/swift.sh` preserves other Git settings and
  applies it only to its SwiftPM process tree, never global Git configuration.
- Installation uses local/ad-hoc signing and does not require paid membership.
- Settings > Copilot offers local CLI or MCP setup, previews changes, backs up
  originals, and preserves unrelated instructions/servers. Use only a route
  permitted by organization policy.

Commands from the project directory:

```sh
bash Scripts/swift.sh test
bash Scripts/build-app.sh --install
open "$HOME/Applications/Ticket Tracker.app"
python3 Scripts/test-integration.py \
  "$HOME/Applications/Ticket Tracker.app/Contents/MacOS/ticket-tracker"
"$HOME/Applications/Ticket Tracker.app/Contents/MacOS/ticket-tracker" setup-copilot
"$HOME/Applications/Ticket Tracker.app/Contents/MacOS/ticket-tracker" setup-copilot --mode cli
```

The helper's `setup-copilot` command previews the personal configuration target
without changing files. The default remains MCP for command compatibility;
`--mode cli` updates only the scoped personal instruction block and leaves
MCP configuration byte-identical. Add `--confirm` only after reviewing and
approving the change. The desktop Settings > Copilot flow uses the same
preservation and backup implementation.

The UI validation fixture is debug-only, requires an isolated data-directory
override, and does not schedule notifications or edit Copilot settings. It
captures only the application's own native views, not the desktop or other apps.
Build it with `bash Scripts/build-app.sh --ui-validation`, which prints the
validation app path and uses the separate `com.tickettracker.local.validation`
identifier. Launch that app's `Contents/MacOS/TicketTracker` executable with
`TICKET_TRACKER_UI_SMOKE=1`, `TICKET_TRACKER_DATA_DIR` pointing to an isolated
temporary directory, and `TICKET_TRACKER_UI_OUTPUT` pointing to the screenshot
directory. The fixture checks the ordinary native window minimum before
isolating its own window from tiling interference; it never changes the
user's tiling-manager settings.

## 17. Installed version and validation results

Version 0.1.0 is installed at `~/Applications/Ticket Tracker.app`. The release
app was opened normally and verified to have finished launching with a
native workspace window. The shared store is in local Application Support,
outside OneDrive. Synthetic fixtures were kept out of the real workspace.

Completed checks:

- Swift strict formatting/lint and a warning-free production build.
- Twenty-two passing domain, persistence, concurrency, recovery, configuration,
  and MCP tests.
- Installed-helper stdio integration: initialization, discovery of nine tools,
  guarded no-QA progression, QA fix/reapproval/retest without reverting the
  QA board move, and competing helper processes rejecting stale writes.
- Real setup-command preview/preservation/backup checks against isolated
  configuration files, including CLI setup that leaves MCP configuration
  byte-identical and does not create it when absent.
- Installed standalone CLI integration: command discovery, JSON argument and
  stdin handling, explicit errors and bounded input, no-QA progression,
  QA fix/reapproval/retest, multiple independent CLI writers, idempotent
  creation, task follow-ups, and literal multiline work context.
- Native rendering and inspection of empty/populated workspaces, QA fixes,
  new-item/settings sheets, and dark appearance.
- Responsive native layouts at 420x360, 720x450, 720x600, 1000x500, 1360x360,
  and 1360x900; window minimum, selection retention, narrow action buttons,
  and scrolling to the bottom of small detail/new-item/settings views.
- Wide and minimum-size Copilot settings with the CLI/MCP choice and
  scrollable permission/setup guidance.
- Strict local signature verification of the release app and nested helper.

The personal Copilot setup was explicitly approved and installed. Existing
configuration was backed up under
`~/.copilot/ticket-tracker-setup-backups`. Copilot CLI discovers the personal
instructions and lists the `ticket-tracker` server as enabled. No repository or
shared workspace configuration was changed and no permanent tool approvals
were added.

**Confirmed integration blocker: organization MCP policy.** Fresh Copilot CLI
1.0.105 sessions recognize the configuration but do not expose tracker tools.
The bundled Copilot SDK, with managed settings explicitly enabled, reports
`ticket-tracker` in `host.filteredServers`, with no connected server and no
tools. The installed helper passes direct JSON-RPC subprocess tests; the
managed client is filtering the server rather than failing its protocol.
Organization approval/allowlisting is required for the MCP route. Saved MCP
configuration does not mean its tools are operational. Do not disable managed
settings or use another route to bypass the policy. The user subsequently
confirmed that a separate local CLI integration is permitted; see section 19.

Notifications and launch at login remain opt-in. Actual notification delivery
and login launch have not been exercised. Jira/GitLab/Teams actions remain
guided manual actions in this version, including choosing real Teams mentions.
The user's actual starter prompt and work-service/contact defaults still need
their real values rather than fabricated examples.

## 18. Small-window and tiling update

The installed app now has a 420x320 content minimum instead of 1120x720;
native title-bar chrome adds some height. The normal native minimum was
verified to fit within a 420x360 window.

- At widths of at least 1120 points, keep the full sidebar.
- Below 1120, replace the sidebar with a compact workspace menu.
- At widths of at least 900, show the item list and detail together.
- Below 900, show one pane with a Back to items control; retain the selected
  item when resizing.
- Use denser headers and hide summary metrics in short windows. Reflow search,
  filters, and action buttons rather than imposing a wider window minimum.
- Bound sheets to their parent window, keep forms and detail content
  scrollable, and keep form footer controls reachable.

The responsive release was installed and reopened after an approved restart.
Saved data and personal Copilot configuration were preserved.

## 19. Organization-permitted local CLI integration

The user explicitly confirmed that Copilot may use a local CLI integration.
The signed installed helper now exposes standalone commands without starting
an MCP transport, web server, or daemon. They call the same validated operation
handlers and store as MCP, retaining workflow guards, revision/generation
checks, idempotent writes, and bounded context. No raw database editing,
waivers, catch-up flags, or automatic external confirmations are exposed.

| Command | Purpose |
| --- | --- |
| `commands` | Discover operation descriptions and JSON input schemas without opening storage |
| `health` | Check helper/storage readiness |
| `list` | Read bounded next-action, waiting, follow-up, all, or archive summaries |
| `get` | Read an item, its current token, steps, and recent history |
| `create` | Find/create a ticket or create a personal task |
| `update` | Save actual details, notes, QA decisions, waits, and follow-up dates |
| `add-mr` | Attach an actual MR URL |
| `record` | Record a confirmed action, rework, or reopening |
| `set-completion-time` | Correct a completed item's actual finish time without changing workflow or merge facts |
| `check` | Check handoff, merge, or completion prerequisites without advancing |
| `draft` | Prepare a message without marking it posted |

```sh
tracker="$HOME/Applications/Ticket Tracker.app/Contents/MacOS/ticket-tracker"
"$tracker" commands
"$tracker" health
"$tracker" list --json '{"view":"next"}'
```

Commands accept a JSON object with `--stdin` or `--json '<object>'`.
Prefer literal stdin for work context, since command-line arguments can appear
in process listings. Input is capped at 1 MiB. Successful operations return
JSON on stdout; operation failures return JSON on stderr and exit status 1.
Command syntax, JSON decoding, and storage failures also use stderr and a
nonzero status. Never interpret a failed command as saved state.

Mutations require the latest item ID, generation, and expected revision plus
a unique request ID. Reuse an ID only with the same operation and arguments
to retry that write. Reread after a conflict; do not silently overwrite it.

After an explicitly approved app restart and setup preview, the personal
tracker instruction block was updated to describe these commands, their
exact installed helper path, discovery, guards, and normal terminal
permissions. Unrelated instructions were preserved and originals were backed
up under `~/.copilot/ticket-tracker-setup-backups`. MCP configuration was
verified byte-identical; no managed setting or permanent tool approval changed.
Future sessions using the same personal instructions can load the CLI guidance.
This does not promise automatic model compliance or authorize external actions.

Fresh normal Copilot CLI sessions loaded the personal guidance and selected
the correct helper and discovery command. The noninteractive model-driven
write check did not proceed: shell execution required interactive approval
that the test could not provide. No task was created by those sessions.
Standalone installed-CLI read/write and workflow tests passed independently;
fresh-session model-driven writes still need an interactive permission check.
Do not confuse instruction discovery with permission to execute commands.

Active sessions do not hot-reload edited custom instructions. Exit and resume
with `copilot --continue` to retain the conversation and reload the files, or
start a new session. `/instructions` shows the instruction files discovered
for the current session.

## 20. Installed appearance and workflow refinements

The source and isolated design preview now contain fixed-appearance themes:
Classic and Linen are light; Slate, Cozy fireplace, and Deep space are dark.
There is no separate light/dark switch. Theme selection is on the main screen.
Fireplace and Space have layered animated backgrounds behind translucent
surfaces. Space now has continuous depth-dependent star drift, breathing
nebula light, and slowly changing planetary illumination, not just meteors.
Ambient animations continue while the window is visible but unfocused and
pause when hidden/minimized, explicitly paused, or Reduce Motion is enabled.

A separate circle toggle beside the theme selector shows/hides a large,
low-contrast breathing guide behind the interface. Its glass-like gradient
rim, soft atmospheric halo, fine inner reflection, and quiet focus point use
theme-specific hues. The circle expands smoothly for five seconds and
contracts for five seconds, with no holds, flashing, or foreground labels.
It fades in/out and respects the same animation/accessibility controls.
These are visual pacing cues, not a medical feature.

All items is first in both the sidebar and compact navigation and is the
default opening view. A standard native title bar restores native window
controls rather than treating the custom workspace header as a title bar.

Board-move buttons open the configured Kanban board with `selectedIssue`
replaced by the current ticket key; ordinary Jira context links still open
the issue page. Existing settings gain the supplied board default without
losing their other saved values. CLI/MCP item context also includes the
ticket-specific `jiraBoardURL`.

Every ordinary completion button first presents an action-specific
confirmation. Opening or cancelling it does not save. Confirming uses the
captured revision, so a newer change from another session produces a conflict
instead of accidentally completing a newer review round. The popup explains
that recording an external action does not perform it.

Desktop-only **Undo last confirmation** returns the most recent current
confirmation to pending, including an accidental final completion. It requires
a reason, preserves append-only history and the current cycle, restores a
completion-cleared follow-up when available, and never reverses anything in
Jira, Teams, or GitLab. Undo requests also capture their original revision.
Older confirmations cannot be removed underneath later confirmations.

After all current MR approvals, the derived phase no longer says Awaiting
approvals. Required-QA work shows Ready for QA, then Ready for QA handoff after
the board move; those pending external actions still need separate
confirmations. Merge/handoff guards are unchanged.

Message preparation carries the selected message kind and item as one sheet
request, with the editor initialized from that kind. Approval requests open
the approval draft, and QE handoffs/retests open the QA draft on the first
presentation rather than briefly/defaulting to kickoff. Drafting/copying
still does not record a sent message.

Validation so far: 29 Swift tests passed, including approval-phase,
backward-compatible settings, board-link, guarded undo, follow-up restoration,
and persistence/idempotency regressions. Real CLI and stdio process integration
tests passed, including the corrected QA phase and ticket-specific board URL,
using the signed packaged release helper as well as the debug helper.
The native fixture passed wide, tiled, and minimum-size layouts, all five
fixed theme appearances, visible-unfocused Space motion, breathing motion and
pause, first-presentation approval/QE/retest draft selection and text,
completion cancellation/confirmation/stale-token safety, and audited undo.
The sidebar order and breathing contrast were also inspected in native
screenshots. Swift formatting/lint and signed debug/release builds passed.

The design preview has a separate bundle identity and reuses only its
isolated sample-data store. Preview/validation bundles require an explicit
data directory even when opened outside the launcher, rather than silently
opening real ticket storage.

After an explicitly approved restart, the signed release was installed at
`~/Applications/Ticket Tracker.app` and reopened against the original live
store. The original store generation and schema were verified unchanged;
the previous app remains under `~/Library/Caches/TicketTracker/PreviousApps`.
The installed helper passed the complete isolated CLI/stdio integration
suite, including the corrected QA phase and board URL. The sample-data
preview was then normally closed to avoid confusing it with the updated
regular app.

The approved CLI instruction refresh added the board-link guidance only
inside the owned tracker block. Unrelated instructions were verified
byte-for-byte identical, and the MCP configuration hash remained unchanged.
Original configuration files were backed up under
`~/.copilot/ticket-tracker-setup-backups/FA5E6C9F-46C7-4AB8-ACE2-7FE6916EF21D`.
The installed helper path is unchanged, so ongoing sessions receive the
corrected workflow context on their next read without a data migration.

## 21. Stand-up summary (included in 0.2.0)

The isolated preview adds **Stand-up summary** immediately after **All items**
in both navigation layouts. All items remains the normal app's default.
The first summary preview opened that page for review. At the user's request,
preview startup is now restored to All items in source; it takes effect in
the next approved native preview build. Summary remains available in navigation.

The report includes every active ticket, regardless of its age, plus tickets
completed within a rolling 48-hour window. Personal tasks are excluded, and
the main item list's search/type filters do not hide tickets from the report.
Active tickets are ordered naturally by Jira key; recent completions are
newest first. Rows show the recorded workflow phase, next action or wait,
prerequisites, explicitly entered waiting-on context, and MR review/merge
progress. Completed rows show their completion time. Each ticket can be
opened directly, and **Copy summary** prepares plain-text meeting notes.
This does not fetch live Jira/Teams state or post anything externally.

Completion time is persisted when the workflow actually becomes complete,
including when its last missing gate is not the final Jira confirmation.
Older records without this optional field derive their completion time from
current confirmed facts, not their last metadata edit. Undo/reopening returns
a ticket to the active section; a later completion gets its new completion
time. The visible report refreshes its time window once a minute.

The desktop loads a full workspace snapshot rather than inheriting the
bounded CLI list's 2,000-item default. Settings and the database change token
are read alongside it. Existing CLI list bounds remain unchanged.

Preview wording also replaces "Saved to your workspace" with "Saved on this
Mac"; setting a follow-up confirms its actual local date and time. Reminder
timing and optional notification behavior are unchanged.

Validation: 35 Swift tests, strict formatting/lint, signed preview and native
validation builds, and the complete isolated CLI/stdio subprocess suite pass.
Coverage includes the exact 48-hour boundary, older/future completions, task
exclusion, retained active tickets beyond the list limit, legacy decoding,
persisted completion dates, undo/recompletion/reopen, and external-writer
refresh. Native summary captures cover empty, wide, tiled, minimum-size,
scrolled completion, and post-undo states. The installed app, real ticket
data, and personal Copilot configuration are not updated by this preview.
The workflow editor is now delivered with the full update described in section 23.

## 22. Gargantua concept and approved native integration

The user requested an animated black-hole theme, with a moving accretion disk
and gravitational lensing, and approved its visual appearance before authorizing the full app update.
Gargantua is now integrated into the real native theme selector in source.
No new main Ticket Tracker app bundle has been packaged or installed for this
concept. After the user asked why it opened in Safari, a separate signed
**Gargantua Preview.app** was packaged as a native AppKit window hosting the
same visual renderer. It has its own identity, Dock presence, window controls,
and Quit action, and does not load the real tracker store or configuration.

An original, self-contained WebGL visual prototype is in the current session's
`files/gargantua-preview/index.html`. It uses no movie frames, remote assets,
network services, or real ticket data. GPU-rendered bent light paths produce
the central shadow and upper/lower disk images; different disk radii rotate
at different rates, with advected filaments, asymmetric emission, and HDR
bloom. The workspace version dims the background and uses dark glass to
preserve text contrast. The theme-only view shows the effect unobstructed.

The prototype has Pause/Play and Theme only/Show workspace controls. It starts
paused for Reduce Motion, suspends its animation when hidden, and reports
renderer errors explicitly. The mock workspace opens on All items and
demonstrates the requested larger completion control; its confirmation is a
visual demo and does not change any data.

Validation passed in a temporary WebKit host without building the native app:
shader compilation/framebuffers, the live animation loop, differing disk
frames at fixed times, an identical repeated paused frame, wide/smaller layouts,
and clickable primary-action confirmation. Captures of the theme-only and
workspace views were visually inspected. JavaScript syntax and strict lint of
the All items startup change also pass. The standalone preview launcher also
compiles with Swift 6 strict concurrency and warnings-as-errors and passes
signature validation. The visual prototype was first opened in Safari and
then moved to the standalone visual host at the user's request. The user
approved the visuals and subsequently authorized integration into the full
native tracker. The separate concept shells are not the delivered app.

## 23. Full native 0.2.0 delivery

The complete native app is installed at `~/Applications/Ticket Tracker.app`
and opened with Gargantua selected. All items remains the startup page.
The sidebar and compact navigation expose the real Workflow editor.

The shared workflow catalog supports immutable published versions, duplication,
reordering, owners, from/to columns, QA/no-QA/retest conditions, prerequisites,
destinations, message templates, required typed fields, import/export, defaults,
and explicit per-item migration previews. CLI discovery includes `workflow`
list/get/validate/publish/default/preview-adopt/adopt operations. Catalog writes
have generation/revision conflict checks, retry receipts, and an audit trail.
New items capture their published definition; existing tickets are not silently
migrated. Changed action meanings become pending while real merges and history
are preserved.

Developer handoff is the default for new tickets. Ticket MRs merge after the
required approvals/QA. The developer then sets the saved Fix Version/s from the
Tuesday after the last actual ticket MR merge and confirms the Ready to deploy
move; the existing Teams thread also requires the exact message `merged`.
Workspace MRs are explicitly classified, never block completion, and have
merged/unmerged catch-up views that include completed tickets of every age.
Later optional merges preserve the original completion timestamp.

The actual next-action card now has a full-width primary completion control.
The approved local Gargantua renderer runs behind the real SwiftUI interface,
with native pause, Reduce Motion, visibility gating and visible error reporting.
There is no mock workspace or development server in the delivered app.

Validation passed: 46 Swift tests, strict recursive Swift formatting/lint,
signed debug/release bundles, full native wide/tiled/minimum-size interaction
checks, actual WebKit animation/paused/unfocused/visibility tests, and the full
CLI/stdio subprocess suite run against the exact installed helper. A migration
test caught WAL-mode backup headers that were inconvenient for first-time
read-only readers; backups now finalize as self-contained DELETE-journal SQLite
files and the read-only migration-backup check passes.

Before upgrading live schema 1 to 2, the old app and preview were closed normally
and a coherent portable SQLite backup was verified. The upgrade preserved the
store generation and both original items/settings payloads byte-for-byte.
The previous app was retained by the installer. Only the tracker-owned Copilot
instruction block was refreshed, with originals backed up at
`~/.copilot/ticket-tracker-setup-backups/73E203C5-A85C-42F3-BA47-7BAD9361E45F`.
Unrelated instruction bytes and the entire MCP configuration were verified
unchanged. Old schema-1 binaries must use the pre-upgrade database backup rather
than writing the new schema.

## 24. Native usability 0.3.0 delivery

The user approved the final native design and authorized full validation and
installation on October 29, 2026. Version 0.3.0 is installed at
`~/Applications/Ticket Tracker.app` and opened normally on Desktop 4. Design
iterations used a separate native preview and isolated sample store; none of
that sample data was imported into the live workspace.

- Larger ticket keys and status; shorter main-screen copy.
- Workspace-wide Notes and Links, separate from tickets, with search/editing.
  Their shared storage is revision-checked and included in export/restore.
- Subtle stage colors on ticket cards: implementation, review, QA, and merge.
- Original full-width completion button, slightly taller at 52 points minimum.
  The current-action and Links cards keep their original stacked layout.
  Ticket-list stage rails remain 4 points wide.
- Compact native completion sheet: action headline, short confirmation, separate
  tracker-only notice, and clear Cancel/Confirm buttons.
- Workflow editor access stays at the top right in every layout, not the sidebar.
- Developer handoff v2 requires posting MR builds as a Jira issue
  comment before QA handoff and again for new builds before retest. No-QA
  tickets skip it. The generic `issue` destination opens the ticket itself.
  Version 2 is published as the default for new tickets. Published v1 and every
  existing ticket's captured workflow remain unchanged; migration is explicit.

The approved iteration process is to defer test suites and snapshots until
the visuals are agreed or an error requires investigation. Preview iterations
retain compile/launch checks and necessary workflow configuration validation.
The user requested this preview on Desktop 4.

Final validation passed: 50 Swift tests, strict recursive Swift lint, plist
validation, full CLI/stdio subprocess suites for debug and the exact signed
optimized release helper, and native Notes/Links, editor, responsive layout,
completion/cancel/stale-token, undo, draft, workflow, and theme/motion checks.
The actual approved workflow definition also passed isolated QA handoff,
rework/retest, no-QA, and existing-ticket preservation scenarios.

A rehearsal on a private copy of live data and the actual schema-2 to schema-3
upgrade both preserved every existing table's bytes and the store generation.
Both original items decoded successfully. Publishing the new default did not
change existing items, settings, or ordinary action receipts. Every installed
bundle file matches the validated release candidate.

Portable, integrity-checked backups are retained in
`~/Library/Application Support/TicketTracker/Backups/`:

- `before-0.3.0-20261029-192902.sqlite` (schema 2).
- `before-schema-3-57956058-D579-4B71-830F-210B2723AD03.sqlite` (automatic schema 2).
- `after-0.3.0-20261029-193351.sqlite` (schema 3, including the new workflow).

The previous app is retained at
`~/Library/Caches/TicketTracker/PreviousApps/0.2.0-20261029-192902.app`.
Do not run it against schema 3; rollback requires the matching schema-2 backup.

The active Copilot CLI instruction block already matches the canonical
generator, including immediate actual merge-timestamp synchronization. No
instruction or MCP configuration bytes were changed for this installation.
Validation logs, the published workflow export, and preservation proofs are in
the current session's `files/usability-release-validation/`.

## 25. Historical completion corrections, 0.3.1

Version 0.3.1 is installed and verified on Desktop 4. Copilot can use the
organization-permitted `set-completion-time` CLI operation to correct an
already-completed ticket or task. Its shared service tool is
`tracker_set_completion_time`; no MCP permissions or configuration were changed.

The operation requires the latest item token, a unique request ID, an actual
ISO8601 `completed_at` timestamp with time zone, and a nonempty `note` explaining
the source/reason. Evidence uses the existing `userConfirmed`, `performed`, or
`verified` values. Historical times may predate tracker creation; future and
invalid dates, incomplete items, and stale writes are rejected. Retries reuse
the exact request ID and arguments without duplicating history.

Only the existing completion metadata is changed. History records the old and
new dates, evidence, reason, source, and current recording time. Workflow
confirmations, MR actual merge times, and Fix Version/s are preserved. Optional
workspace-MR catch-up retains the corrected date. Undo/reopening clears completion
as before, and completing the work again records its new finish time.

Stand-up already filters by actual completion date within the last 48 hours,
not the time a backfill or correction was entered. Older backfills therefore
stay out of the recent-completions summary. No real ticket completion dates
were changed during this installation, and no UI design changes were made.

Validation passed: all 52 Swift tests, strict recursive Swift lint, plist
validation, and full CLI/stdio subprocess suites for both debug and the exact
signed release helper. Focused cases cover historical and legacy records,
summary filtering, audit history, invalid input, concurrency/retry safety,
reopening, and preservation of merge facts through workspace catch-up.

Schema remains 3. Every installed bundle file matches the tested release;
all live tables and the store generation were verified unchanged. A portable,
integrity-checked backup is retained at
`~/Library/Application Support/TicketTracker/Backups/before-0.3.1-20261029-202017.sqlite`.
The previous matching schema-3 app is retained at
`~/Library/Caches/TicketTracker/PreviousApps/0.3.0-20261029-202017.app`.

The tracker-owned Copilot CLI instruction block now documents actual completion
corrections, evidence, and reread verification. Unrelated instruction bytes and
the complete MCP configuration were verified unchanged. Originals are backed up
at `~/.copilot/ticket-tracker-setup-backups/2A114A6C-B5F0-48CE-8C72-67F939DBEA4B`.
Delivery logs and preservation proofs are in the current session's
`files/completion-time-validation/`.

## 26. Planning views, quick switcher and celebrations, 0.4.0

Version 0.4.0 is installed after preview approval. Changes:

- Grouped sidebar (Work, Reviews, Reference) without per-row counts.
- Releases view grouping tickets by saved or projected Fix Version/s, plus
  tickets still awaiting merge and releases from the last three weeks.
- End-of-day review: today's progress, what is still on me, waiting items and
  follow-ups due by tomorrow. Backfilled completions from earlier days are
  excluded.
- ⌃⌥Space floating quick switcher with in-panel ticket detail: complete and
  confirm the next step, copy messages, links, follow-ups and checklist. It
  returns to the list after completing.
- Required fields (such as Fix Version/s) can be entered inline on the
  next-step card in the app and the popup. The suggested version is prefilled.
- Gargantua breathing guide pulses the accretion disk glow instead of zooming.
- Insights: median time per stage (build, review, QA, merge, release), tickets
  in flight compared with usual, and the share of tickets with rework.
  Backfilled tickets are excluded.
- Brag doc: shipped tickets by month with optional impact notes, copied as
  Markdown. Completed items accept edits only to the `brag-impact` field.
- Confetti and a "KEY is done" card when a ticket reaches Done, with a
  monthly count. This can be toggled in the theme menu.

Validation: 57 Swift tests (new focused cases for Insights, Brag doc, Releases,
End-of-day backfill exclusion and impact-only edits on completed items),
strict lint, and the full CLI/stdio integration suite against the signed
release helper. Installed bundle hashes match the tested build; live data and
store generation are unchanged. Backup:
`Backups/before-0.4.0-20261030-184957.sqlite`. The previous app is retained at
`~/Library/Caches/TicketTracker/PreviousApps/0.3.1-20261030-184957.app`. The
Copilot instruction block now documents `brag-impact`; nothing outside the
block changed.

## 0.5.0 release (October 30, 2026)

Version 0.5.0 is installed after preview approval. Changes: animated themes
(Gargantua, Aurora, Skyline, Rain, Nebula, Cabin, Christmas, Bonsai), the
floating breathing guide, workflow-editor improvements (step presets, drag
reorder, Fix order, custom paths, wait nudges, Test drive simulator, undo/redo)
with matching CLI/MCP ops and Copilot instructions, the completed-ticket
selection fix, and an embedded terminal (SwiftTerm 1.99.2) with tabs, ⌘J/⌘T
shortcuts, a resizable/maximizable panel, and a Settings starting folder.
