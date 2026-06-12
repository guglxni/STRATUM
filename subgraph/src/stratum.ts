import { BigInt, Bytes } from "@graphprotocol/graph-ts"
import {
  TrancheDeposited,
  TrancheSettled,
  SwapAccounted,
  EpochClosed,
  JuniorReserveUpdated,
  CoverageStress,
  PositionMigrated,
  ProtocolFeeRealizationSet,
  ProtocolFeeRealized,
  ProtocolFeesCollected,
  ReserveFunded
} from "../generated/StratumHook/StratumHook"
import {
  Pool,
  Position,
  Epoch,
  Swap,
  CoverageStressEvent,
  Migration,
  ProtocolFeeRealizedEvent,
  ProtocolFeeCollection
} from "../generated/schema"

// TrancheType: SENIOR = 0, JUNIOR = 1 (src/StratumTypes.sol).
function trancheLabel(t: i32): string {
  return t == 0 ? "SENIOR" : "JUNIOR"
}

function getOrCreatePool(poolId: Bytes, ts: BigInt): Pool {
  let id = poolId.toHexString()
  let p = Pool.load(id)
  if (p == null) {
    p = new Pool(id)
    p.currentEpoch = BigInt.zero()
    p.seniorDeposited = BigInt.zero()
    p.juniorDeposited = BigInt.zero()
    p.juniorReserve = BigInt.zero()
    p.swapCount = BigInt.zero()
    p.feeAccumulated = BigInt.zero()
    p.lastCoverageRatioBps = 0
    p.lastStressLevel = 0
    p.protocolFeeRealization = false
    p.protocolFeeValueRealized = BigInt.zero()
    p.createdAt = ts
  }
  p.updatedAt = ts
  return p as Pool
}

export function handleTrancheDeposited(event: TrancheDeposited): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.poolId, ts)
  let label = trancheLabel(event.params.tranche)
  // Cumulative gross liquidity deposited into each tranche (running total, not net of withdrawals).
  if (label == "SENIOR") {
    pool.seniorDeposited = pool.seniorDeposited.plus(event.params.liquidity)
  } else {
    pool.juniorDeposited = pool.juniorDeposited.plus(event.params.liquidity)
  }
  pool.save()

  let pos = new Position(event.params.positionId.toHexString())
  pos.pool = pool.id
  pos.owner = event.params.owner
  pos.tranche = label
  pos.liquidity = event.params.liquidity
  pos.open = true
  pos.entryEpoch = event.params.epoch
  pos.depositedAt = ts
  pos.migrationCount = BigInt.zero()
  pos.save()
}

export function handleTrancheSettled(event: TrancheSettled): void {
  let pos = Position.load(event.params.positionId.toHexString())
  if (pos == null) return
  pos.open = false
  pos.payout = event.params.payout
  pos.ilCharged = event.params.ilCharged
  pos.settledAt = event.block.timestamp
  pos.save()
}

export function handleSwapAccounted(event: SwapAccounted): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.poolId, ts)
  pool.swapCount = pool.swapCount.plus(BigInt.fromI32(1))
  pool.feeAccumulated = pool.feeAccumulated.plus(event.params.feeAmount)
  pool.lastCoverageRatioBps = event.params.coverageRatioBps
  pool.save()

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let s = new Swap(id)
  s.pool = pool.id
  s.epoch = event.params.epoch
  s.feeAmount = event.params.feeAmount
  s.volatilityEWMA = event.params.volatilityEWMA
  s.coverageRatioBps = event.params.coverageRatioBps
  s.timestamp = ts
  s.txHash = event.transaction.hash
  s.save()
}

export function handleEpochClosed(event: EpochClosed): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.poolId, ts)
  // closeEpoch increments the epoch after emitting; track the next epoch as current.
  pool.currentEpoch = event.params.epoch.plus(BigInt.fromI32(1))
  pool.save()

  let id = event.params.poolId.toHexString() + "-" + event.params.epoch.toString()
  let e = new Epoch(id)
  e.pool = pool.id
  e.epoch = event.params.epoch
  e.seniorFunded = event.params.seniorFunded
  e.juniorSurplus = event.params.juniorSurplus
  e.juniorReserve = pool.juniorReserve // refined by the JuniorReserveUpdated that follows in the same tx
  e.closedAt = ts
  e.save()
}

export function handleJuniorReserveUpdated(event: JuniorReserveUpdated): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.poolId, ts)
  pool.juniorReserve = event.params.juniorReserve
  pool.save()

  let id = event.params.poolId.toHexString() + "-" + event.params.epoch.toString()
  let e = Epoch.load(id)
  if (e != null) {
    e.juniorReserve = event.params.juniorReserve
    e.save()
  }
}

export function handleCoverageStress(event: CoverageStress): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.poolId, ts)
  pool.lastCoverageRatioBps = event.params.ratioBps
  pool.lastStressLevel = event.params.stressLevel
  pool.save()

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let c = new CoverageStressEvent(id)
  c.pool = pool.id
  c.ratioBps = event.params.ratioBps
  c.stressLevel = event.params.stressLevel
  c.timestamp = ts
  c.save()
}

export function handlePositionMigrated(event: PositionMigrated): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.poolId, ts)
  pool.save()

  let toLabel = trancheLabel(event.params.toTranche)
  let pos = Position.load(event.params.positionId.toHexString())
  if (pos != null) {
    pos.tranche = toLabel
    pos.migrationCount = pos.migrationCount.plus(BigInt.fromI32(1))
    pos.save()
  }

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let m = new Migration(id)
  m.pool = pool.id
  m.position = event.params.positionId.toHexString()
  m.owner = event.params.owner
  m.fromTranche = trancheLabel(event.params.fromTranche)
  m.toTranche = toLabel
  m.carriedPrincipal = event.params.carriedPrincipal
  m.realizedIL = event.params.realizedIL
  m.timestamp = ts
  m.save()
}

export function handleProtocolFeeRealizationSet(event: ProtocolFeeRealizationSet): void {
  let pool = getOrCreatePool(event.params.id, event.block.timestamp)
  pool.protocolFeeRealization = event.params.enabled
  pool.save()
}

export function handleProtocolFeeRealized(event: ProtocolFeeRealized): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.poolId, ts)
  pool.protocolFeeValueRealized = pool.protocolFeeValueRealized.plus(event.params.value0)
  pool.save()

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let r = new ProtocolFeeRealizedEvent(id)
  r.pool = pool.id
  r.amount0 = event.params.amount0
  r.amount1 = event.params.amount1
  r.value0 = event.params.value0
  r.timestamp = ts
  r.save()
}

export function handleProtocolFeesCollected(event: ProtocolFeesCollected): void {
  let ts = event.block.timestamp
  let pool = getOrCreatePool(event.params.id, ts)
  pool.save()

  let id = event.transaction.hash.toHexString() + "-" + event.logIndex.toString()
  let c = new ProtocolFeeCollection(id)
  c.pool = pool.id
  c.to = event.params.to
  c.amount0 = event.params.amount0
  c.amount1 = event.params.amount1
  c.timestamp = ts
  c.save()
}

export function handleReserveFunded(event: ReserveFunded): void {
  // The token-backed junior buffer (reserve0/1) is distinct from the juniorReserve accumulator; this handler
  // keeps the pool's updatedAt fresh so consumers see liveness. Detailed buffer tracking is intentionally
  // left to the lens read path (StratumLens.reserveBalances).
  let pool = getOrCreatePool(event.params.poolId, event.block.timestamp)
  pool.save()
}
