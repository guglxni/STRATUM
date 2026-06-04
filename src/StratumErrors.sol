// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title StratumErrors
/// @notice Custom errors for STRATUM (named after violated condition).
library StratumErrors {
    error CoverageRatioBelowFloor();
    error EpochNotElapsed();
    error ConservationViolation();
    error NotPositionOwner();
    error TrancheMismatch();
    error PeripheralDisabled();
    error ProofInvalid();
    error FeeBoundsInvalid();
    error PoolNotInitialized();
    error PositionNotFound();
    error PositionAlreadyExists();
    error ClaimAtSettlement();
    error Unauthorized();
}
