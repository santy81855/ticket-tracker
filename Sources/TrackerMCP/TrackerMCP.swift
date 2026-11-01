import Foundation
import MCP
import TrackerCore
import TrackerStore

public actor TrackerMCPService {
  public let store: TrackerStore
  public init(store: TrackerStore) { self.store = store }

  private static func field(_ type: String, _ description: String) -> Value {
    .object(["type": .string(type), "description": .string(description)])
  }

  private static func strings(_ description: String) -> Value {
    .object([
      "type": .string("array"), "items": .object(["type": .string("string")]),
      "description": .string(description),
    ])
  }

  private static func tool(
    _ name: String, _ description: String, fields: [String: Value] = [:], required: [String] = []
  ) -> Tool {
    Tool(
      name: name, description: description,
      inputSchema: .object([
        "type": .string("object"), "properties": .object(fields),
        "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false),
      ]))
  }

  public static var tools: [Tool] {
    let id = field(
      "string", "The stable tracker item ID (get_item also accepts an unambiguous Jira key).")
    let text = field("string", "Text supplied by the user or actual work context, never invented.")
    let evidence = field(
      "string",
      "userConfirmed, performed, or verified. Default userConfirmed. A direct user statement counts; no duplicate checkbox needed."
    )
    let mutation = [
      "item_id": id, "generation": field("string", "Store generation from the latest item token."),
      "expected_revision": field("integer", "Item revision from the latest token."),
      "request_id": field(
        "string", "Unique request ID. Reuse exactly the same ID and arguments only when retrying."),
    ]
    let required = ["item_id", "generation", "expected_revision", "request_id"]
    return [
      tool("tracker_health", "Check local storage and helper readiness."),
      tool(
        "tracker_list_items",
        "List a bounded page of actionable items or waits. Does not include full ticket bodies.",
        fields: [
          "view": field(
            "string",
            "next, waiting, followups, all, archive, workspaceUnmerged, or workspaceMerged. followups includes scheduled follow-ups and overdue wait-step nudges. Workspace views include completed tickets of every age."
          ), "search": text,
          "limit": field("integer", "1–50, defaults to 25."),
          "offset": field("integer", "Page offset, defaults to zero."),
        ]),
      tool(
        "tracker_get_item",
        "Read the current ticket/task, token, next actions, prerequisites, and recent history before any change.",
        fields: ["item_id": id], required: ["item_id"]),
      tool(
        "tracker_create_item",
        "Find/create a Jira ticket by identity, or create a personal task. No external API calls.",
        fields: [
          "kind": field("string", "ticket or task"), "title": text,
          "jira": field("string", "Full Jira URL or key using the configured base URL."),
          "qa": field(
            "string", "undecided, required, or notRequired. Never infer no-QA from the title."),
          "qa_reason": field("string", "Explicit user-provided reason if selecting notRequired."),
          "notes": text, "request_id": field("string", "Unique request ID for safe retries."),
          "workflow_id": field(
            "string", "Published workflow ID. Omit to use the persisted default."),
        ], required: ["kind", "title", "request_id"]),
      tool(
        "tracker_update_details",
        "Save known notes/links or dates. QA removal requires an explicit user decision. Never weakens guards.",
        fields: mutation.merging([
          "title": text, "notes": text,
          "thread_url": field("string", "HTTPS Teams thread URL; empty clears it."),
          "testing_notes": text, "environment": text, "qe": text, "waiting_on": text,
          "qa": field("string", "undecided, required, or notRequired."), "qa_reason": text,
          "follow_up_at": field("string", "ISO 8601 timestamp, including time zone."),
          "clear_follow_up": field("boolean", "True to remove the follow-up."),
          "field_values": field(
            "object",
            "Workflow field ID to known string value, including fix-version. Never invent required information."
          ),
          "paths": strings(
            "Replaces the item's custom workflow path IDs (from its workflow's paths). Empty list = standard path. Only set paths the user explicitly chose; never to skip a blocker."
          ),
        ]) { _, new in new }, required: required),
      tool(
        "tracker_add_mr",
        "Attach or explicitly classify a GitLab MR. Ticket MRs affect readiness. Workspace MRs never block completion, and may be added/merged after completion.",
        fields: mutation.merging([
          "url": field("string", "HTTPS MR URL, required when adding."),
          "mr_id": field("string", "Existing MR ID when explicitly changing classification."),
          "role": field(
            "string",
            "ticket or workspace. Defaults to ticket; never infer role from repository name."),
        ]) { _, new in new },
        required: required),
      tool(
        "tracker_record_action",
        "Record an actual performed/verified fact or explicit user report. After performing an authorized action (such as merging), update the tracker yourself. Jira board moves require userConfirmed. Missing other obligations remain open. This records facts, never authorizes external actions. rework and reopen are supported.",
        fields: mutation.merging([
          "action_id": field("string", "An exact step ID, rework, or reopen."),
          "note": field(
            "string",
            "Explicit user-reported external confirmation, or description of material changes/finding."
          ),
          "evidence": evidence,
          "occurred_at": field(
            "string",
            "Actual ISO8601 event time, required for ticket merges in configured workflows. Use GitLab merged_at, not the time an old merge was recorded."
          ),
        ]) { _, new in new },
        required: required + ["action_id", "note"]),
      tool(
        "tracker_set_completion_time",
        "Correct an already-completed item's actual finish time, including historical backfills. Audited metadata only: does not complete work, skip steps, or change MR merge times. Stand-up uses this date, not the correction time.",
        fields: mutation.merging([
          "completed_at": field(
            "string",
            "Actual ISO8601 completion timestamp with time zone, not in the future. May predate tracker creation. Use a user-reported or verified time; never invent one to hide a ticket."
          ),
          "note": field("string", "Required explanation and source of the actual completion time."),
          "evidence": evidence,
        ]) { _, new in new },
        required: required + ["completed_at", "note"]),
      tool(
        "tracker_check_transition",
        "Read-only prerequisite check. Does not advance or complete anything.",
        fields: [
          "item_id": id,
          "target": field(
            "string",
            "approvalRequest, qaHandoff, retestHandoff, merge, done, or an exact configured step ID."
          ),
        ],
        required: ["item_id", "target"]),
      tool(
        "tracker_get_message_draft",
        "Prepare a workflow step message (including post-merge merged) or a kickoff/approvals/qa draft. Preparing is not posting. Select real Teams mentions.",
        fields: [
          "item_id": id, "kind": field("string", "kickoff, approvals, or qa."),
          "action_id": field(
            "string", "Exact workflow step ID; uses its configured message template."),
        ],
        required: ["item_id"]),
      tool(
        "tracker_workflow",
        "Read/export, validate, test-drive, publish, select defaults, or explicitly migrate a ticket workflow when the user requests it. Published versions are immutable. Never change rules just to bypass a blocker. Publishing never silently migrates existing tickets.",
        fields: [
          "op": field(
            "string",
            "list, get, presets, columns, validate, simulate, publish, default, preview-adopt, or adopt. presets returns starter custom steps; columns lists known Jira board columns; simulate walks a definition (or workflow_id) with a sample ticket without changing data."
          ),
          "preset": field(
            "string", "For presets: return only this preset's step (e.g. waitOn)."),
          "qa": field("string", "For simulate: required (default), notRequired, or undecided."),
          "retest": field("boolean", "For simulate: model a QE retest round."),
          "paths": strings("For simulate: custom path IDs to take."),
          "completed": strings(
            "For simulate: step IDs to treat as done, in order. MR steps cover every sample MR."),
          "workflow_id": field("string", "Published workflow ID."),
          "workflow_version": field("integer", "Specific published version. Required for adopt."),
          "definition": field(
            "object",
            "Full WorkflowDefinition JSON. Get an existing definition, edit its steps/owners/fromColumn/toColumn/dependencies/conditions/fields/messages, validate, then publish. A new ID duplicates it."
          ),
          "reason": field("string", "The explicit user request, required for all writes."),
          "make_default": field(
            "boolean", "Use the newly published version as the default for new items."),
          "generation": field("string", "Current store generation."),
          "expected_revision": field(
            "integer", "Catalog revision for publish/default, item revision for adopt."),
          "request_id": field("string", "Unique retry-safe write ID."),
          "item_id": id,
          "confirm_migration": field(
            "boolean",
            "True only after the user requested applying the previewed workflow to this existing ticket."
          ),
        ], required: ["op"]),
    ]
  }

  public func call(name: String, arguments: [String: Value]) async -> CallTool.Result {
    do {
      try validateArguments(name: name, arguments: arguments)
      switch name {
      case "tracker_health":
        struct Health: Encodable {
          var version = "0.5.0"
          var schema = TrackerStore.schemaVersion
          var generation: String
          var ready = true
        }
        return try result(Health(generation: try await store.generation()))
      case "tracker_list_items":
        let view = try optionalString("view", arguments) ?? "next"
        guard
          [
            "next", "waiting", "followups", "all", "archive", "workspaceUnmerged",
            "workspaceMerged",
          ].contains(view)
        else {
          throw TrackerError.invalid("Unknown list view.")
        }
        let limit = try optionalInt("limit", arguments) ?? 25
        let offset = try optionalInt("offset", arguments) ?? 0
        guard (1...50).contains(limit), (0...1_000_000).contains(offset) else {
          throw TrackerError.invalid("Invalid list limit/offset.")
        }
        let search = try optionalString("search", arguments) ?? ""
        let snapshots =
          view.hasPrefix("workspace")
          ? try await store.workspaceSnapshot().items : try await store.list(limit: 5000)
        let all = snapshots.filter { snapshot in
          let item = snapshot.item
          let matchesSearch =
            search.isEmpty
            || "\(item.jiraKey) \(item.title)".localizedCaseInsensitiveContains(search)
          let matchesView: Bool
          switch view {
          case "archive": matchesView = item.isDone
          case "waiting": matchesView = !item.isDone && snapshot.isWaiting
          case "followups":
            matchesView = !item.isDone && (item.followUpAt != nil || !snapshot.nudges.isEmpty)
          case "all": matchesView = true
          case "workspaceUnmerged":
            matchesView = item.workspaceMRs.contains { !item.has(.mergeMR, mrID: $0.id) }
          case "workspaceMerged":
            matchesView =
              !item.workspaceMRs.isEmpty
              && item.workspaceMRs.allSatisfy { item.has(.mergeMR, mrID: $0.id) }
          default:
            matchesView = snapshot.hasActionableWork
          }
          return matchesSearch && matchesView
        }
        struct Summary: Encodable {
          var id: String
          var title: String
          var jiraKey: String
          var phase: String
          var nextAction: String?
          var followUpAt: Date?
          var nudges: [String]?
          var token: RevisionToken
        }
        struct Page: Encodable {
          var total: Int
          var nextOffset: Int?
          var items: [Summary]
        }
        let page = all.dropFirst(offset).prefix(limit).map {
          Summary(
            id: $0.id, title: $0.item.title, jiraKey: $0.item.jiraKey, phase: $0.phase,
            nextAction: $0.nextStep?.title, followUpAt: $0.item.followUpAt,
            nudges: $0.nudges.isEmpty ? nil : $0.nudges.compactMap(\.nudge), token: $0.token)
        }
        return try result(
          Page(
            total: all.count, nextOffset: offset + limit < all.count ? offset + limit : nil,
            items: page))
      case "tracker_get_item":
        return try await context(try await store.get(requiredString("item_id", arguments)))
      case "tracker_create_item":
        guard let kind = ItemKind(rawValue: try requiredString("kind", arguments)) else {
          throw TrackerError.invalid("kind must be ticket or task.")
        }
        let qa = try qaValue(arguments) ?? .undecided
        let qaReason = try optionalString("qa_reason", arguments) ?? ""
        if qa == .notRequired && qaReason.isEmpty {
          throw TrackerError.invalid("An explicit user-provided qa_reason is required to skip QA.")
        }
        var input = NewItem(
          kind: kind, title: try requiredString("title", arguments),
          jira: try optionalString("jira", arguments) ?? "", qa: qa,
          notes: try optionalString("notes", arguments) ?? "")
        input.workflowID = try optionalString("workflow_id", arguments)
        return try await context(
          try await store.create(
            input, source: .copilot, requestID: requiredString("request_id", arguments)))
      case "tracker_update_details", "tracker_add_mr", "tracker_record_action",
        "tracker_set_completion_time":
        let mutation: ItemMutation
        if name == "tracker_set_completion_time" {
          mutation = .correctCompletionTime(
            try parseDate(requiredString("completed_at", arguments)),
            note: try requiredString("note", arguments), evidence: try factEvidence(arguments))
        } else if name == "tracker_add_mr" {
          let rawRole = try optionalString("role", arguments) ?? "ticket"
          guard let role = MRRole(rawValue: rawRole) else {
            throw TrackerError.invalid("role must be ticket or workspace.")
          }
          if let id = try optionalString("mr_id", arguments) {
            guard arguments["url"] == nil else {
              throw TrackerError.invalid("Use mr_id to classify, or url to add; not both.")
            }
            mutation = .classifyMR(id: id, role: role)
          } else {
            let url = try requiredString("url", arguments)
            mutation = role == .workspace ? .addWorkspaceMR(url) : .addMR(url)
          }
        } else if name == "tracker_record_action" {
          let action = try requiredString("action_id", arguments)
          let note = try string("note", arguments)
          if action == "rework" {
            mutation = .rework(note)
          } else if action == "reopen" {
            mutation = .reopen
          } else {
            let evidence = try factEvidence(arguments)
            if arguments["evidence"] != nil || arguments["occurred_at"] != nil {
              mutation = .recordFact(
                FactInput(
                  actionID: action, note: note, evidence: evidence,
                  occurredAt: try optionalString("occurred_at", arguments).map(parseDate)))
            } else {
              mutation = .record(actionID: action, note: note)
            }
          }
        } else {
          var patch = DetailsPatch()
          patch.title = try optionalString("title", arguments)
          patch.notes = try optionalString("notes", arguments)
          patch.threadURL = try optionalString("thread_url", arguments)
          patch.testingNotes = try optionalString("testing_notes", arguments)
          patch.environment = try optionalString("environment", arguments)
          patch.qe = try optionalString("qe", arguments)
          patch.waitingOn = try optionalString("waiting_on", arguments)
          patch.qa = try qaValue(arguments)
          patch.qaReason = try optionalString("qa_reason", arguments)
          if let values = arguments["field_values"] {
            guard case .object(let fields) = values,
              fields.values.allSatisfy({ $0.stringValue != nil })
            else {
              throw TrackerError.invalid("field_values must map field IDs to strings.")
            }
            patch.fieldValues = fields.compactMapValues(\.stringValue)
          }
          if case .array(let values) = arguments["paths"] {
            patch.paths = values.compactMap(\.stringValue)
          }
          if let date = try optionalString("follow_up_at", arguments) {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var parsed = parser.date(from: date)
            if parsed == nil {
              parser.formatOptions = [.withInternetDateTime]
              parsed = parser.date(from: date)
            }
            guard let parsed else {
              throw TrackerError.invalid(
                "follow_up_at must be an ISO 8601 timestamp with time zone.")
            }
            patch.followUpAt = parsed
          }
          if let value = arguments["clear_follow_up"] {
            guard let flag = value.boolValue else {
              throw TrackerError.invalid("clear_follow_up must be boolean.")
            }
            patch.clearFollowUp = flag
          }
          mutation = .edit(patch)
        }
        guard let version = try optionalInt("expected_revision", arguments), version >= 1 else {
          throw TrackerError.invalid("expected_revision must be a positive integer.")
        }
        let snapshot = try await store.mutate(
          requiredString("item_id", arguments),
          expected: RevisionToken(
            generation: requiredString("generation", arguments), version: version),
          mutation: mutation, source: .copilot, requestID: requiredString("request_id", arguments)
        )
        return try await context(snapshot)
      case "tracker_check_transition":
        let snapshot = try await store.get(requiredString("item_id", arguments))
        let target = try requiredString("target", arguments)
        let blockers: [String]
        if target == "merge" {
          guard snapshot.item.kind == .ticket else {
            throw TrackerError.invalid("Personal tasks do not have a merge transition.")
          }
          blockers = Workflow.mergeBlockers(for: snapshot.item)
        } else if target == "done", snapshot.item.workflow != nil {
          blockers = snapshot.steps.filter { $0.state == .pending && $0.isOptional != true }.map {
            "Complete: \($0.title)"
          }
        } else if let step = snapshot.steps.first(where: { $0.id == target }),
          snapshot.item.workflow != nil
        {
          blockers = step.blockers
        } else {
          let kind: ActionKind
          switch target {
          case "approvalRequest": kind = .approvalRequest
          case "qaHandoff": kind = .qaHandoff
          case "retestHandoff": kind = .retestHandoff
          case "done": kind = snapshot.item.kind == .task ? .taskDone : .jiraDone
          default: throw TrackerError.invalid("Unknown transition target.")
          }
          guard let step = snapshot.steps.first(where: { $0.kind == kind }),
            step.state != .notApplicable
          else {
            throw TrackerError.invalid("This transition does not apply to the current playbook.")
          }
          blockers = step.blockers
        }
        struct Check: Encodable {
          var allowed: Bool
          var blockers: [String]
          var token: RevisionToken
        }
        return try result(
          Check(allowed: blockers.isEmpty, blockers: blockers, token: snapshot.token))
      case "tracker_get_message_draft":
        let snapshot = try await store.get(requiredString("item_id", arguments))
        if let action = try optionalString("action_id", arguments) {
          return try result(
            Messages.draft(actionID: action, item: snapshot.item, settings: await store.settings()))
        }
        guard let kind = DraftKind(rawValue: try requiredString("kind", arguments)) else {
          throw TrackerError.invalid("Unknown draft kind.")
        }
        return try result(
          Messages.draft(kind, item: snapshot.item, settings: await store.settings()))
      case "tracker_workflow":
        return try await workflow(arguments)
      default: throw TrackerError.invalid("Unknown tool.")
      }
    } catch {
      return failure(error)
    }
  }
  private func factEvidence(_ arguments: [String: Value]) throws -> FactEvidence {
    guard
      let evidence = FactEvidence(
        rawValue: try optionalString("evidence", arguments) ?? "userConfirmed")
    else {
      throw TrackerError.invalid("Unknown fact evidence.")
    }
    return evidence
  }
  private func parseDate(_ text: String) throws -> Date {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = parser.date(from: text) { return date }
    parser.formatOptions = [.withInternetDateTime]
    guard let date = parser.date(from: text) else {
      throw TrackerError.invalid("Use an ISO8601 timestamp with timezone.")
    }
    return date
  }
  private func workflow(_ args: [String: Value]) async throws -> CallTool.Result {
    let op = try requiredString("op", args)
    let snapshot = try await store.workflows()
    struct Index: Encodable {
      var generation: String
      var revision: Int
      var defaultTicketID: String
      var defaultTaskID: String
      struct Entry: Encodable {
        var id: String
        var name: String
        var kind: ItemKind
        var version: Int
      }
      var workflows: [Entry]
    }
    func index(_ value: WorkflowCatalogSnapshot) -> Index {
      Index(
        generation: value.generation, revision: value.catalog.revision,
        defaultTicketID: value.catalog.defaultTicketID,
        defaultTaskID: value.catalog.defaultTaskID,
        workflows: value.catalog.latest.map {
          Index.Entry(id: $0.id, name: $0.name, kind: $0.kind, version: $0.version)
        })
    }
    func definition() throws -> WorkflowDefinition {
      guard let encoded = args["definition"], case .object = encoded else {
        throw TrackerError.invalid("Supply the full definition object.")
      }
      let value = try StoreJSON.decode(WorkflowDefinition.self, from: StoreJSON.encode(encoded))
      try value.validate()
      return value
    }
    func strings(_ key: String) throws -> [String] {
      guard let value = args[key] else { return [] }
      guard case .array(let values) = value else {
        throw TrackerError.invalid("\(key) must be a list.")
      }
      return values.compactMap(\.stringValue)
    }
    if op == "list" { return try result(index(snapshot)) }
    if op == "presets" {
      struct Preset: Encodable {
        var preset: String
        var name: String
        var summary: String
        var step: WorkflowRule
      }
      let wanted = try optionalString("preset", args)
      let presets = WorkflowStepPreset.allCases.filter { wanted == nil || $0.rawValue == wanted }
      guard !presets.isEmpty else { throw TrackerError.invalid("Unknown preset.") }
      return try result(
        presets.map {
          Preset(preset: $0.rawValue, name: $0.displayName, summary: $0.summary, step: $0.rule())
        })
    }
    if op == "columns" { return try result(snapshot.catalog.knownColumns) }
    if op == "validate" {
      let value = try definition()
      struct Validation: Encodable {
        var valid = true
        var warnings: [String]
        var suggestedOrder: [String]?
      }
      return try result(
        Validation(
          warnings: value.warnings + snapshot.catalog.columnWarnings(for: value),
          suggestedOrder: value.isInPrerequisiteOrder
            ? nil : value.orderedByPrerequisites().map(\.id)))
    }
    if op == "simulate" {
      let target: WorkflowDefinition
      if args["definition"] != nil {
        target = try definition()
      } else {
        let id = try requiredString("workflow_id", args)
        guard
          let found = snapshot.catalog.definition(
            id, version: try optionalInt("workflow_version", args))
        else { throw TrackerError.invalid("Unknown workflow/version.") }
        target = found
      }
      guard let qa = QARequirement(rawValue: try optionalString("qa", args) ?? "required") else {
        throw TrackerError.invalid("qa must be required, notRequired, or undecided.")
      }
      return try result(
        WorkflowSimulator.simulate(
          target, qa: qa, retest: args["retest"]?.boolValue ?? false, paths: try strings("paths"),
          completed: try strings("completed"), settings: try await store.settings()))
    }
    if op == "get" || op == "preview-adopt" || op == "adopt" {
      let id = try requiredString("workflow_id", args)
      let version = try optionalInt("workflow_version", args)
      guard let target = snapshot.catalog.definition(id, version: version) else {
        throw TrackerError.invalid("Unknown workflow/version.")
      }
      if op == "get" { return try result(target) }
      let item = try await store.get(requiredString("item_id", args))
      if op == "preview-adopt" {
        return try result(ConfiguredWorkflow.migrationPreview(item.item, to: target))
      }
      guard version != nil, args["confirm_migration"]?.boolValue == true else {
        throw TrackerError.invalid(
          "Preview the migration, then supply workflow_version and confirm_migration for the user-requested adoption."
        )
      }
      guard let revision = try optionalInt("expected_revision", args), revision >= 1 else {
        throw TrackerError.invalid("Supply the current item revision.")
      }
      return try await context(
        await store.mutate(
          item.id,
          expected: RevisionToken(
            generation: requiredString("generation", args), version: revision),
          mutation: .adoptWorkflow(target, reason: requiredString("reason", args)),
          source: .copilot,
          requestID: requiredString("request_id", args)))
    }
    guard op == "publish" || op == "default" else {
      throw TrackerError.invalid("Unknown workflow operation.")
    }
    guard let revision = try optionalInt("expected_revision", args), revision >= 0 else {
      throw TrackerError.invalid("Supply the current catalog revision from workflow list.")
    }
    let reason = try requiredString("reason", args)
    let change: WorkflowCatalogMutation =
      op == "publish"
      ? .publish(
        try definition(), reason: reason, makeDefault: args["make_default"]?.boolValue ?? false)
      : .setDefault(id: try requiredString("workflow_id", args), reason: reason)
    let updated = try await store.changeWorkflows(
      change,
      expected: RevisionToken(
        generation: requiredString("generation", args), version: revision),
      source: .copilot, requestID: requiredString("request_id", args))
    return try result(index(updated))
  }
  private func failure(_ error: Error) -> CallTool.Result {
    struct Failure: Encodable {
      var error: String
      var code: String
      var recovery: String
    }
    let code: String
    if let error = error as? TrackerError, case .conflict = error {
      code = "conflict"
    } else {
      code = "operation_failed"
    }
    do {
      return try result(
        Failure(
          error: error.localizedDescription, code: code,
          recovery: code == "conflict"
            ? "Read the item or workflow catalog again, then retry with a new request ID and current token."
            : "Correct the reported problem before retrying."), isError: true)
    } catch {
      return .init(
        content: [
          .text(
            text: "Failed to encode the tool error: \(error.localizedDescription)",
            annotations: nil, _meta: nil)
        ], isError: true)
    }
  }

  private func validateArguments(name: String, arguments: [String: Value]) throws {
    guard let tool = Self.tools.first(where: { $0.name == name }),
      case .object(let schema) = tool.inputSchema,
      case .object(let properties) = schema["properties"]
    else { throw TrackerError.invalid("Unknown tool.") }
    guard arguments.keys.allSatisfy({ properties[$0] != nil }) else {
      throw TrackerError.invalid(
        "Unknown argument; arbitrary fields and bypass flags are not accepted.")
    }
    for (name, value) in arguments {
      guard case .object(let field) = properties[name], let type = field["type"]?.stringValue else {
        throw TrackerError.invalid("Invalid operation schema.")
      }
      let valid: Bool
      switch type {
      case "string": valid = value.stringValue != nil
      case "integer": valid = value.intValue != nil
      case "boolean": valid = value.boolValue != nil
      case "object": if case .object = value { valid = true } else { valid = false }
      case "array":
        if case .array(let values) = value {
          valid = values.count <= 60 && values.allSatisfy { $0.stringValue != nil }
        } else {
          valid = false
        }
      default: valid = false
      }
      guard valid else { throw TrackerError.invalid("\(name) must be \(type).") }
    }
    if case .array(let required) = schema["required"] {
      for name in required.compactMap(\.stringValue) where arguments[name] == nil {
        throw TrackerError.invalid("Missing required argument: \(name).")
      }
    }
  }
  private func string(_ key: String, _ args: [String: Value]) throws -> String {
    guard let value = args[key]?.stringValue, value.count <= 100_000 else {
      throw TrackerError.invalid("\(key) must be a string of at most 100,000 characters.")
    }
    return value
  }
  private func requiredString(_ key: String, _ args: [String: Value]) throws -> String {
    let value = try string(key, args)
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw TrackerError.invalid("\(key) cannot be empty.")
    }
    return value
  }
  private func optionalString(_ key: String, _ args: [String: Value]) throws -> String? {
    guard args[key] != nil else { return nil }
    return try string(key, args)
  }
  private func optionalInt(_ key: String, _ args: [String: Value]) throws -> Int? {
    guard let raw = args[key] else { return nil }
    guard let value = raw.intValue else { throw TrackerError.invalid("\(key) must be an integer.") }
    return value
  }
  private func qaValue(_ args: [String: Value]) throws -> QARequirement? {
    guard let text = try optionalString("qa", args) else { return nil }
    guard let value = QARequirement(rawValue: text) else {
      throw TrackerError.invalid("Unknown QA requirement.")
    }
    return value
  }
  private func context(_ snapshot: ItemSnapshot) async throws -> CallTool.Result {
    struct Context: Encodable {
      var snapshot: ItemSnapshot
      var phase: String
      var steps: [WorkflowStep]
      var nextAction: WorkflowStep?
      var reportedNotVerified = true
      var truncated: Bool
      var jiraBoardURL: String?
    }
    var bounded = snapshot
    let truncated =
      bounded.item.notes.count > 12_000 || bounded.item.testingNotes.count > 12_000
      || bounded.item.history.count > 20
    bounded.item.notes = String(bounded.item.notes.prefix(12_000))
    bounded.item.testingNotes = String(bounded.item.testingNotes.prefix(12_000))
    bounded.item.history = Array(bounded.item.history.suffix(20))
    let settings = try await store.settings()
    let board =
      snapshot.item.kind == .ticket && !settings.jiraBoardURL.isEmpty
      ? try Workflow.jiraBoardLink(settings.jiraBoardURL, issueKey: snapshot.item.jiraKey) : nil
    return try result(
      Context(
        snapshot: bounded, phase: snapshot.phase, steps: snapshot.steps,
        nextAction: snapshot.nextStep, truncated: truncated, jiraBoardURL: board))
  }
  private func result<T: Encodable>(_ value: T, isError: Bool = false) throws -> CallTool.Result {
    let data = try StoreJSON.encode(value, pretty: true)
    return .init(
      content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
      isError: isError)
  }

  public static func serve(store: TrackerStore) async throws {
    let service = TrackerMCPService(store: store)
    let server = Server(
      name: "ticket-tracker", version: "0.5.0", capabilities: .init(tools: .init()))
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: Self.tools) }
    await server.withMethodHandler(CallTool.self) { params in
      await service.call(name: params.name, arguments: params.arguments ?? [:])
    }
    try await server.start(transport: StdioTransport())
    await server.waitUntilCompleted()
  }
}
