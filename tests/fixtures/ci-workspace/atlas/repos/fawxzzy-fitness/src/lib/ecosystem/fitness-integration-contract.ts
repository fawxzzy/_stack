import type {
  BoundedActionContract,
  DeterministicSignalFixture,
  DeterministicStateSnapshotFixture,
  EcosystemIntegrationContract,
  ReceiptContract,
  SignalContract,
  StateSnapshotContract,
  ValidationResult,
} from "./contract-types";

export const fitnessSignalTypes = [
  "workout_completed",
  "workout_missed",
  "recovery_warning",
  "weekly_goal_hit",
  "streak_broken",
  "pilot_shadow_impression_logged",
  "pilot_shadow_click_logged",
  "pilot_placement_dismissed",
  "pilot_support_complaint_opened",
  "pilot_activation_retained",
] as const;

export type FitnessSignalType = (typeof fitnessSignalTypes)[number];

export const fitnessStateSnapshotTypes = [
  "athlete_readiness_state",
  "weekly_progress_state",
  "streak_health_state",
] as const;

export type FitnessStateSnapshotType = (typeof fitnessStateSnapshotTypes)[number];

export const fitnessReceiptTypes = [
  "schedule_adjustment_applied",
  "recovery_guardrail_applied",
  "goal_plan_amended",
] as const;

export type FitnessReceiptType = (typeof fitnessReceiptTypes)[number];

export const fitnessActionTypes = [
  "adjust_upcoming_workout_load",
  "schedule_recovery_block",
  "revise_weekly_goal_plan",
] as const;

export type FitnessActionType = (typeof fitnessActionTypes)[number];

type SchemaValue = string | number | boolean;

const fitnessSignals: readonly SignalContract<FitnessSignalType>[] = [
  {
    type: "workout_completed",
    version: 1,
    description: "Emitted when a planned workout session is completed.",
    payloadSchema: {
      memberId: "string",
      sessionId: "string",
      completedAt: "ISO-8601",
      durationMinutes: "number",
      completionRate: "number",
    },
    routing: {
      target: "playbook",
      channel: "fitness.session.events",
      priority: "normal",
      maxDeliveryLatencySeconds: 60,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "workout_missed",
    version: 1,
    description: "Emitted when a planned workout session was not completed.",
    payloadSchema: {
      memberId: "string",
      sessionId: "string",
      scheduledAt: "ISO-8601",
      missReasonCode: "string",
      consecutiveMisses: "number",
    },
    routing: {
      target: "playbook",
      channel: "fitness.session.events",
      priority: "high",
      maxDeliveryLatencySeconds: 60,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "recovery_warning",
    version: 1,
    description: "Emitted when readiness or fatigue scores cross configured limits.",
    payloadSchema: {
      memberId: "string",
      readinessScore: "number",
      fatigueScore: "number",
      warningLevel: "string",
      observedAt: "ISO-8601",
    },
    routing: {
      target: "playbook",
      channel: "fitness.recovery.events",
      priority: "high",
      maxDeliveryLatencySeconds: 30,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "weekly_goal_hit",
    version: 1,
    description: "Emitted when a member reaches their weekly completion target.",
    payloadSchema: {
      memberId: "string",
      weekStartDate: "YYYY-MM-DD",
      workoutsPlanned: "number",
      workoutsCompleted: "number",
      achievedAt: "ISO-8601",
    },
    routing: {
      target: "playbook",
      channel: "fitness.goal.events",
      priority: "normal",
      maxDeliveryLatencySeconds: 120,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "streak_broken",
    version: 1,
    description: "Emitted when an active workout streak ends.",
    payloadSchema: {
      memberId: "string",
      streakDaysBeforeBreak: "number",
      breakDate: "YYYY-MM-DD",
      lastCompletedWorkoutAt: "ISO-8601",
      breakReasonCode: "string",
    },
    routing: {
      target: "playbook",
      channel: "fitness.streak.events",
      priority: "high",
      maxDeliveryLatencySeconds: 60,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "pilot_shadow_impression_logged",
    version: 1,
    description: "Emitted when the shadow-only recovery reset placement would have been shown to an eligible member.",
    payloadSchema: {
      memberId: "string",
      sourceOutboundId: "string",
      placementId: "string",
      surfaceId: "string",
      cohortId: "string",
      observedAt: "ISO-8601",
    },
    routing: {
      target: "playbook",
      channel: "fitness.growth.shadow.events",
      priority: "normal",
      maxDeliveryLatencySeconds: 60,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "pilot_shadow_click_logged",
    version: 1,
    description: "Emitted when a member clicks the shadow-measured recovery reset destination.",
    payloadSchema: {
      memberId: "string",
      sourceOutboundId: "string",
      placementId: "string",
      destinationPath: "string",
      cohortId: "string",
      clickedAt: "ISO-8601",
    },
    routing: {
      target: "playbook",
      channel: "fitness.growth.shadow.events",
      priority: "high",
      maxDeliveryLatencySeconds: 60,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "pilot_placement_dismissed",
    version: 1,
    description: "Emitted when a member dismisses the recovery reset placement.",
    payloadSchema: {
      memberId: "string",
      sourceOutboundId: "string",
      placementId: "string",
      dismissalReasonCode: "string",
      dismissedAt: "ISO-8601",
    },
    routing: {
      target: "playbook",
      channel: "fitness.growth.feedback.events",
      priority: "normal",
      maxDeliveryLatencySeconds: 120,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "pilot_support_complaint_opened",
    version: 1,
    description: "Emitted when the pilot placement results in a support complaint that must count against widening.",
    payloadSchema: {
      memberId: "string",
      sourceOutboundId: "string",
      placementId: "string",
      complaintCode: "string",
      openedAt: "ISO-8601",
    },
    routing: {
      target: "playbook",
      channel: "fitness.growth.feedback.events",
      priority: "high",
      maxDeliveryLatencySeconds: 300,
    },
    requiresPlaybookIngestion: true,
  },
  {
    type: "pilot_activation_retained",
    version: 1,
    description: "Emitted when a destination activation remains retained through the frozen pilot window.",
    payloadSchema: {
      memberId: "string",
      sourceOutboundId: "string",
      placementId: "string",
      retentionWindowDays: "number",
      retainedAt: "ISO-8601",
    },
    routing: {
      target: "playbook",
      channel: "fitness.growth.retention.events",
      priority: "normal",
      maxDeliveryLatencySeconds: 300,
    },
    requiresPlaybookIngestion: true,
  },
];

const fitnessStateSnapshots: readonly StateSnapshotContract<FitnessStateSnapshotType>[] = [
  {
    type: "athlete_readiness_state",
    version: 1,
    description: "Inspectable readiness signal surface used by planning.",
    inspectableFields: ["memberId", "readinessScore", "fatigueScore", "capturedAt"],
    freshnessSlaSeconds: 300,
  },
  {
    type: "weekly_progress_state",
    version: 1,
    description: "Inspectable weekly adherence surface for the active week.",
    inspectableFields: [
      "memberId",
      "weekStartDate",
      "plannedWorkoutCount",
      "completedWorkoutCount",
      "capturedAt",
    ],
    freshnessSlaSeconds: 300,
  },
  {
    type: "streak_health_state",
    version: 1,
    description: "Inspectable streak continuity surface for behavioral planning.",
    inspectableFields: ["memberId", "activeStreakDays", "lastCompletedDate", "streakAtRisk", "capturedAt"],
    freshnessSlaSeconds: 300,
  },
];

const fitnessReceipts: readonly ReceiptContract<FitnessReceiptType>[] = [
  {
    type: "schedule_adjustment_applied",
    version: 1,
    description: "Receipt generated when workout load adjustments are accepted.",
    requiredFields: ["receiptId", "actionType", "memberId", "appliedAt", "adjustmentSummary"],
  },
  {
    type: "recovery_guardrail_applied",
    version: 1,
    description: "Receipt generated when a recovery block is scheduled.",
    requiredFields: ["receiptId", "actionType", "memberId", "appliedAt", "recoveryMinutes"],
  },
  {
    type: "goal_plan_amended",
    version: 1,
    description: "Receipt generated when weekly plan targets are updated.",
    requiredFields: ["receiptId", "actionType", "memberId", "appliedAt", "newWorkoutTarget"],
  },
];

const fitnessActions: readonly BoundedActionContract<FitnessActionType, FitnessReceiptType>[] = [
  {
    type: "adjust_upcoming_workout_load",
    version: 1,
    description: "Adjusts upcoming workout targets using bounded load deltas.",
    inputSchema: [
      {
        name: "memberId",
        type: "string",
        required: true,
        description: "Member identity for the adjustment.",
      },
      {
        name: "loadDeltaPercent",
        type: "number",
        required: true,
        description: "Bounded percent change applied to upcoming workout load.",
        min: -30,
        max: 30,
      },
      {
        name: "effectiveUntil",
        type: "string",
        required: true,
        description: "Inclusive end date for the temporary adjustment.",
      },
    ],
    receiptType: "schedule_adjustment_applied",
    constraints: [
      "must_route_through_playbook_plan",
      "max_duration_days_14",
      "no_direct_lifeline_bypass",
    ],
    routing: {
      target: "lifeline",
      channel: "fitness.actions.training-load",
      priority: "normal",
      maxDeliveryLatencySeconds: 300,
    },
  },
  {
    type: "schedule_recovery_block",
    version: 1,
    description: "Schedules bounded recovery time after warning signals.",
    inputSchema: [
      {
        name: "memberId",
        type: "string",
        required: true,
        description: "Member identity for recovery scheduling.",
      },
      {
        name: "recoveryMinutes",
        type: "number",
        required: true,
        description: "Recovery duration to block in the calendar.",
        min: 15,
        max: 180,
      },
      {
        name: "reasonCode",
        type: "string",
        required: true,
        description: "Deterministic recovery reason enum value.",
        allowedValues: ["elevated_fatigue", "sleep_deficit", "high_load_streak"],
      },
    ],
    receiptType: "recovery_guardrail_applied",
    constraints: ["must_route_through_playbook_plan", "no_direct_lifeline_bypass"],
    routing: {
      target: "lifeline",
      channel: "fitness.actions.recovery",
      priority: "high",
      maxDeliveryLatencySeconds: 120,
    },
  },
  {
    type: "revise_weekly_goal_plan",
    version: 1,
    description: "Revises the weekly plan inside bounded workout target limits.",
    inputSchema: [
      {
        name: "memberId",
        type: "string",
        required: true,
        description: "Member identity for the weekly revision.",
      },
      {
        name: "newWorkoutTarget",
        type: "number",
        required: true,
        description: "New weekly workout target bounded by governance limits.",
        min: 1,
        max: 14,
      },
      {
        name: "weekStartDate",
        type: "string",
        required: true,
        description: "Week start date in YYYY-MM-DD.",
      },
    ],
    receiptType: "goal_plan_amended",
    constraints: ["must_route_through_playbook_plan", "no_direct_lifeline_bypass", "same_week_only"],
    routing: {
      target: "lifeline",
      channel: "fitness.actions.weekly-plan",
      priority: "normal",
      maxDeliveryLatencySeconds: 300,
    },
  },
];

export const fitnessIntegrationContract: EcosystemIntegrationContract = {
  identity: {
    appId: "fitness",
    appName: "Fawxzzy Fitness",
    appVersion: "1.0.0",
    ecosystemRole: "sensor-actuator",
  },
  governance: {
    loop: "signal->plan->action->receipt",
    seam: "playbook-lifeline",
    bypassAllowed: false,
  },
  signals: fitnessSignals,
  stateSnapshots: fitnessStateSnapshots,
  actions: fitnessActions,
  receipts: fitnessReceipts,
};

function validateSchemaValue(
  value: unknown,
  schemaType: string,
  options: {
    fieldName: string;
    errors: string[];
  },
): void {
  const { fieldName, errors } = options;
  if (schemaType === "number") {
    if (typeof value !== "number" || Number.isNaN(value)) {
      errors.push(`Field '${fieldName}' must be a number`);
    }
    return;
  }

  if (schemaType === "boolean") {
    if (typeof value !== "boolean") {
      errors.push(`Field '${fieldName}' must be a boolean`);
    }
    return;
  }

  if (schemaType === "YYYY-MM-DD") {
    if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
      errors.push(`Field '${fieldName}' must be a YYYY-MM-DD string`);
    }
    return;
  }

  if (schemaType === "ISO-8601") {
    if (typeof value !== "string" || Number.isNaN(Date.parse(value))) {
      errors.push(`Field '${fieldName}' must be an ISO-8601 string`);
    }
    return;
  }

  if (typeof value !== "string") {
    errors.push(`Field '${fieldName}' must be a string`);
  }
}

function validatePayloadSchema(
  schema: Readonly<Record<string, string>>,
  payload: Readonly<Record<string, SchemaValue>>,
  options: {
    contextLabel: string;
  },
): string[] {
  const { contextLabel } = options;
  const errors: string[] = [];

  for (const [fieldName, schemaType] of Object.entries(schema)) {
    if (!(fieldName in payload)) {
      errors.push(`Missing payload field '${fieldName}' on ${contextLabel}`);
      continue;
    }

    validateSchemaValue(payload[fieldName], schemaType, {
      fieldName,
      errors,
    });
  }

  return errors;
}

export function validateSignalFixture(
  fixture: DeterministicSignalFixture,
  contract: EcosystemIntegrationContract = fitnessIntegrationContract,
): ValidationResult {
  const errors: string[] = [];
  const signalContract = contract.signals.find((signal) => signal.type === fixture.signalType);

  if (!signalContract) {
    errors.push(`Unknown signal type: ${fixture.signalType}`);
  } else {
    if (fixture.routing.channel !== signalContract.routing.channel) {
      errors.push(`Routing channel mismatch for ${fixture.fixtureId}`);
    }

    errors.push(
      ...validatePayloadSchema(signalContract.payloadSchema, fixture.payload, {
        contextLabel: `signal fixture ${fixture.fixtureId}`,
      }),
    );
  }

  if (fixture.appId !== contract.identity.appId) {
    errors.push(`Fixture appId '${fixture.appId}' does not match contract appId '${contract.identity.appId}'`);
  }

  return {
    ok: errors.length === 0,
    errors,
  };
}

export function validateStateSnapshotFixture(
  fixture: DeterministicStateSnapshotFixture,
  contract: EcosystemIntegrationContract = fitnessIntegrationContract,
): ValidationResult {
  const errors: string[] = [];
  const snapshotContract = contract.stateSnapshots.find((snapshot) => snapshot.type === fixture.snapshotType);

  if (!snapshotContract) {
    errors.push(`Unknown snapshot type: ${fixture.snapshotType}`);
  } else {
    for (const field of snapshotContract.inspectableFields) {
      if (!(field in fixture.snapshot)) {
        errors.push(`Missing inspectable field '${field}' in snapshot fixture ${fixture.fixtureId}`);
      }
    }
  }

  if (fixture.appId !== contract.identity.appId) {
    errors.push(`Fixture appId '${fixture.appId}' does not match contract appId '${contract.identity.appId}'`);
  }

  return {
    ok: errors.length === 0,
    errors,
  };
}

export function validateReceiptFixture(
  fixture: {
    readonly receiptType: string;
    readonly receiptId: string;
    readonly actionType: string;
    readonly memberId: string;
    readonly appliedAt: string;
    readonly sourceOutboundId: string;
    readonly payload: Readonly<Record<string, SchemaValue>>;
  },
  contract: EcosystemIntegrationContract = fitnessIntegrationContract,
): ValidationResult {
  const errors: string[] = [];
  const receiptContract = contract.receipts.find((receipt) => receipt.type === fixture.receiptType);

  if (!receiptContract) {
    errors.push(`Unknown receipt type: ${fixture.receiptType}`);
  } else {
    for (const fieldName of receiptContract.requiredFields) {
      if (fieldName in fixture) {
        continue;
      }

      if (!(fieldName in fixture.payload)) {
        errors.push(`Missing receipt field '${fieldName}' on receipt ${fixture.receiptId}`);
      }
    }
  }

  if (typeof fixture.receiptId !== "string" || fixture.receiptId.length === 0) {
    errors.push("Receipt id must be a non-empty string");
  }

  if (typeof fixture.actionType !== "string" || fixture.actionType.length === 0) {
    errors.push("Action type must be a non-empty string");
  }

  if (typeof fixture.memberId !== "string" || fixture.memberId.length === 0) {
    errors.push("Member id must be a non-empty string");
  }

  if (typeof fixture.sourceOutboundId !== "string" || fixture.sourceOutboundId.length === 0) {
    errors.push("sourceOutboundId must be a non-empty string");
  }

  if (typeof fixture.appliedAt !== "string" || Number.isNaN(Date.parse(fixture.appliedAt))) {
    errors.push("appliedAt must be an ISO-8601 string");
  }

  return {
    ok: errors.length === 0,
    errors,
  };
}

export function validateActionReceiptMappings(contract: EcosystemIntegrationContract = fitnessIntegrationContract): ValidationResult {
  const errors: string[] = [];
  const knownReceiptTypes = new Set(contract.receipts.map((receipt) => receipt.type));

  for (const action of contract.actions) {
    if (!knownReceiptTypes.has(action.receiptType)) {
      errors.push(`Action ${action.type} references unknown receipt type ${action.receiptType}`);
    }

    if (!action.constraints.includes("must_route_through_playbook_plan")) {
      errors.push(`Action ${action.type} is missing required playbook routing constraint`);
    }
  }

  return {
    ok: errors.length === 0,
    errors,
  };
}
