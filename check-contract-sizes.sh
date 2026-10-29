#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# EIP-170 contract size limit (bytes)
MAX_SIZE=24576

# Core contracts that must stay under the size limit.
# Add any deployable contract that is at risk of exceeding the limit.
CONTRACTS=(
    "UmiaHub"
    "UmiaMarketCore"
    "MarketCreationLib"
    "SettlementLib"
    "UmiaHook"
    "UmiaValidationHook"
    "GovernanceExecutor"
    "Venture"
    "UmiaLBPFactory"
    "UmiaHookV2"
    "SpotLiquidityVaultV2"
    "ActiveLiquidityManager"
    "SpotMigrator"
    "UmiaLBPV2"
    "UmiaLBPFactoryV2"
)

failed=0

for contract in "${CONTRACTS[@]}"; do
    bytecode=$(forge inspect "$contract" deployedBytecode)
    # Strip the 0x prefix and compute byte length (2 hex chars = 1 byte)
    hex="${bytecode#0x}"
    size=$(( ${#hex} / 2 ))
    margin=$(( MAX_SIZE - size ))

    if [ "$size" -gt "$MAX_SIZE" ]; then
        echo "FAIL: $contract — $size bytes (exceeds limit by $(( size - MAX_SIZE )) bytes)"
        failed=1
    else
        echo "OK:   $contract — $size bytes (margin: $margin bytes)"
    fi
done

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "Contract size check failed. One or more core contracts exceed the EIP-170 limit ($MAX_SIZE bytes)."
    echo "Consider splitting logic into libraries or reducing contract complexity."
    exit 1
fi

echo ""
echo "All core contracts are within the EIP-170 size limit."
