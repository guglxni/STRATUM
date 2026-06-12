import { BigInt } from "@graphprotocol/graph-ts"
import {
  IntentRegistered,
  IntentExecuted,
  IntentCancelled
} from "../generated/TrancheIntentRegistry/TrancheIntentRegistry"
import { Intent } from "../generated/schema"

// TrancheType: SENIOR = 0, JUNIOR = 1 (src/StratumTypes.sol).
function trancheLabel(t: i32): string {
  return t == 0 ? "SENIOR" : "JUNIOR"
}

// ConditionType: COVERAGE_BELOW = 0, COVERAGE_ABOVE = 1, SENIOR_APY_BELOW = 2 (TrancheIntentRegistry.sol).
function conditionLabel(c: i32): string {
  if (c == 0) return "COVERAGE_BELOW"
  if (c == 1) return "COVERAGE_ABOVE"
  return "SENIOR_APY_BELOW"
}

export function handleIntentRegistered(event: IntentRegistered): void {
  let intent = new Intent(event.params.intentId.toString())
  intent.positionId = event.params.positionId
  // Link to the indexed Position if it already exists (same hook position id).
  intent.position = event.params.positionId.toHexString()
  intent.lp = event.params.lp
  intent.toTranche = trancheLabel(event.params.toTranche)
  intent.condition = conditionLabel(event.params.conditionType)
  intent.threshold = event.params.threshold
  intent.status = "ACTIVE"
  intent.registeredAt = event.block.timestamp
  intent.save()
}

export function handleIntentExecuted(event: IntentExecuted): void {
  let intent = Intent.load(event.params.intentId.toString())
  if (intent == null) return
  intent.status = "EXECUTED"
  intent.carriedPrincipal = event.params.carriedPrincipal
  intent.resolvedAt = event.block.timestamp
  intent.save()
}

export function handleIntentCancelled(event: IntentCancelled): void {
  let intent = Intent.load(event.params.intentId.toString())
  if (intent == null) return
  intent.status = "CANCELLED"
  intent.resolvedAt = event.block.timestamp
  intent.save()
}
