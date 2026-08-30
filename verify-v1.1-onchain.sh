#!/usr/bin/env bash
# Proves that v1.1/src is the FactoryHook deployed on Robinhood Chain (4663):
#   1. builds v1.1 and takes the compiled runtime bytecode of FactoryHook;
#   2. fetches the runtime bytecode of the deployed hook with `cast code`;
#   3. compares the two with the immutables (BC_TOKEN_FACTORY, WETH) masked and the trailing
#      solc metadata CBOR stripped — i.e. every executable byte;
#   4. rebuilds the CREATE2 initcode (creation bytecode + the constructor arguments it was
#      deployed with, with the metadata IPFS hash taken from the on-chain runtime) and derives
#      the deployment address from it, which must be the address above.
# Requires: forge, cast, jq, python3. Override the RPC with ROBINHOOD_RPC_URL.
set -euo pipefail

HOOK=0xee588bCF2bd3e658f5160489f4199d1851BBf0Cc
CREATE2_DEPLOYER=0x4e59b44847b379578588920ca78fbf26c0b4956c
SALT=0x0000000000000000000000000000000000000000000000000000000000001779
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
TOKEN_FACTORY=0xe3A826C056e578c240D362BF4C2fa53E5c0c17a5
WETH=0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73
STAKING_VAULT_FACTORY=0xFB443f5c6Ba35334a1AB2Fc12d4b877fc2A8d6A9
RPC="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}"
HERE="$(cd "$(dirname "$0")" && pwd)"

cd "$HERE/v1.1"
forge build --silent 2>/dev/null || forge build >/dev/null
ONCHAIN="$(cast code "$HOOK" --rpc-url "$RPC")"
ARGS="$(cast abi-encode 'constructor(address,address,address,address)' \
  "$POOL_MANAGER" "$TOKEN_FACTORY" "$WETH" "$STAKING_VAULT_FACTORY")"
INITCODE_FILE="$(mktemp)"
trap 'rm -f "$INITCODE_FILE"' EXIT

python3 - "$HERE/v1.1/out/FactoryHook.sol/FactoryHook.json" "$ONCHAIN" "$ARGS" "$INITCODE_FILE" <<'PYEOF'
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
    return bytes(code[:-2 - n]), bytes(code[-2 - n:])
c_code, c_meta = split(compiled)
o_code, o_meta = split(onchain)
print(f"executable bytes identical (immutables masked): {c_code == o_code}")
print(f"metadata CBOR identical: {c_meta == o_meta}")
print(f"  compiled ipfs: {c_meta.hex()[20:84]}")
print(f"  on-chain ipfs: {o_meta.hex()[20:84]}")
if c_code != o_code:
    sys.exit("MISMATCH: executable code differs")

# The initcode carries the runtime, metadata included, followed by the constructor arguments.
# Only the metadata IPFS hash differs from the deployer's build (see README), so it is taken
# from the on-chain runtime; every other byte is the one compiled here.
creation = bytes.fromhex(art["bytecode"]["object"][2:])
if creation.count(c_meta) != 1:
    sys.exit("MISMATCH: metadata CBOR is not carried exactly once by the creation bytecode")
open(sys.argv[4], "w").write("0x" + (creation.replace(c_meta, o_meta) + bytes.fromhex(sys.argv[3][2:])).hex())
PYEOF

INITCODE_HASH="$(cast keccak "$(cat "$INITCODE_FILE")")"
DERIVED="$(cast keccak "0xff${CREATE2_DEPLOYER#0x}${SALT#0x}${INITCODE_HASH#0x}")"
DERIVED="0x${DERIVED: -40}"
echo "initcode hash: $INITCODE_HASH"
echo "CREATE2 address: $DERIVED"
if [ "${DERIVED,,}" != "${HOOK,,}" ]; then
  echo "MISMATCH: derived address is not $HOOK" >&2
  exit 1
fi
echo "OK: v1.1 FactoryHook.sol compiles to the executable bytecode deployed at $HOOK,"
echo "    and to the initcode that CREATE2-deploys to that address with salt $SALT."
