#!/usr/bin/env bash
# Proves that v1.0/src is the FactoryHook deployed on Robinhood Chain (4663):
#   1. builds v1.0 and takes the compiled runtime bytecode of FactoryHook;
#   2. fetches the runtime bytecode of the deployed hook with `cast code`;
#   3. compares the two with the immutables (BC_TOKEN_FACTORY, WETH) masked and the trailing
#      solc metadata CBOR stripped — i.e. every executable byte.
# Requires: forge, cast, jq, python3. Override the RPC with ROBINHOOD_RPC_URL.
set -euo pipefail

HOOK=0xb31780AAd49D3Cc7Dd6E03E9e462606F0A5A30Cc
RPC="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
HERE="$(cd "$(dirname "$0")" && pwd)"

cd "$HERE/v1.0"
forge build --silent 2>/dev/null || forge build >/dev/null
ONCHAIN="$(cast code "$HOOK" --rpc-url "$RPC")"

python3 - "$HERE/v1.0/out/FactoryHook.sol/FactoryHook.json" "$ONCHAIN" <<'PYEOF'
import json, sys
art = json.load(open(sys.argv[1]))
compiled = bytearray(bytes.fromhex(art["deployedBytecode"]["object"][2:]))
onchain = bytearray(bytes.fromhex(sys.argv[2][2:]))
print(f"compiled runtime: {len(compiled)} bytes | on-chain runtime: {len(onchain)} bytes")
if len(compiled) != len(onchain):
    sys.exit("MISMATCH: different lengths")
for refs in art["deployedBytecode"].get("immutableReferences", {}).values():
    for r in refs:
        for code in (compiled, onchain):
            code[r["start"]:r["start"] + r["length"]] = b"\0" * r["length"]
def split(code):
    n = int.from_bytes(code[-2:], "big")
    return bytes(code[:-2 - n]), bytes(code[-2 - n:-2])
c_code, c_meta = split(compiled)
o_code, o_meta = split(onchain)
print(f"executable bytes identical (immutables masked): {c_code == o_code}")
print(f"metadata CBOR identical: {c_meta == o_meta}")
print(f"  compiled ipfs: {c_meta.hex()[20:84]}")
print(f"  on-chain ipfs: {o_meta.hex()[20:84]}")
if c_code != o_code:
    sys.exit("MISMATCH: executable code differs")
print("OK: v1.0 FactoryHook.sol compiles to the executable bytecode deployed at", "0xb31780AAd49D3Cc7Dd6E03E9e462606F0A5A30Cc")
PYEOF
