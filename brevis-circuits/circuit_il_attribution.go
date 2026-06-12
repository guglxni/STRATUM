// Package main: STRATUM ILAttribution Brevis ZK circuit.
// Reads poolCumulativeIL from the live STRATUM hook on Sepolia, generates a ZK proof,
// and submits it to the Brevis gateway which delivers it on-chain to BrevisVerifierShim.
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"math/big"
	"os"

	pgoldilocks "github.com/OpenAssetStandards/poseidon-goldilocks-go"
	"github.com/brevis-network/brevis-sdk/sdk"
	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/plonk"
	"github.com/consensys/gnark/constraint"
	gwproto "github.com/brevis-network/brevis-sdk/sdk/proto/gwproto"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
	gethrpc "github.com/ethereum/go-ethereum/rpc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// ---------------------------------------------------------------------------
// AppCircuit
// ---------------------------------------------------------------------------

type ILAttributionCircuit struct{}

var _ sdk.AppCircuit = &ILAttributionCircuit{}

func (c *ILAttributionCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	// Brevis requires storage count to be an integral multiple of 32.
	return 0, 32, 0
}

func (c *ILAttributionCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	slots := sdk.NewDataStream(api, in.StorageSlots)
	ilSlot := sdk.GetUnderlying(slots, 0)
	api.OutputUint(248, api.ToUint248(ilSlot.Value))
	return nil
}

// ---------------------------------------------------------------------------
// Storage slot: poolCumulativeIL is at mapping slot 0 + struct field offset 10.
// ---------------------------------------------------------------------------

func poolCumulativeILSlot(pid common.Hash) common.Hash {
	var slot0 [32]byte
	base := crypto.Keccak256(append(pid.Bytes(), slot0[:]...))
	slotInt := new(big.Int).Add(new(big.Int).SetBytes(base), big.NewInt(10))
	return common.BigToHash(slotInt)
}

// ---------------------------------------------------------------------------
// IPv4-forced Brevis gateway client (bypass IPv6 resolution that resets TLS).
// ---------------------------------------------------------------------------

func getCircuitDigests() (*sdk.BrevisHashInfo, error) {
	tlsCfg := &tls.Config{ServerName: "appsdkv3.brevis.network", MinVersion: tls.VersionTLS12}
	conn, err := grpc.NewClient("100.21.74.230:443", grpc.WithTransportCredentials(credentials.NewTLS(tlsCfg)))
	if err != nil {
		return nil, fmt.Errorf("grpc.NewClient: %w", err)
	}
	gc := gwproto.NewGatewayClient(conn)
	resp, err := gc.GetCircuitDigest(context.Background(), &gwproto.CircuitDigestRequest{})
	if err != nil {
		return nil, fmt.Errorf("GetCircuitDigest: %w", err)
	}
	if len(resp.HashesLimbs) < 12 || len(resp.GnarkVks) < 7 {
		return nil, fmt.Errorf("unexpected GetCircuitDigest response: limbs=%d vks=%d", len(resp.HashesLimbs), len(resp.GnarkVks))
	}
	return sdk.NewBrevisAppWithDigestsSetOnly(
		&pgoldilocks.HashOut256{resp.HashesLimbs[0], resp.HashesLimbs[1], resp.HashesLimbs[2], resp.HashesLimbs[3]},
		&pgoldilocks.HashOut256{resp.HashesLimbs[4], resp.HashesLimbs[5], resp.HashesLimbs[6], resp.HashesLimbs[7]},
		&pgoldilocks.HashOut256{resp.HashesLimbs[8], resp.HashesLimbs[9], resp.HashesLimbs[10], resp.HashesLimbs[11]},
		resp.GnarkVks[0], resp.GnarkVks[1], resp.GnarkVks[2], resp.GnarkVks[3],
		resp.GnarkVks[4], resp.GnarkVks[5], resp.GnarkVks[6],
	).BrevisHashInfo, nil
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const (
	srcChainId     uint64 = 11155111
	dstChainId     uint64 = 11155111
	sepHookAddr           = "0xaf618609340C81c45C201740aF349631bb8ce7c1"
	brevisShimAddr        = "0x96cf69e916fcb17b71957c11e1e3c43a4ea9386d"
	refundAddr            = "0xDDe9D31a31d6763612C7f535f51E5dC9f830682e"
	poolId                = "0x7f71bf30d4ef019df247fcce520a52f05fe9bad33e70f893bd6fea328eb88072"
)

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

func main() {
	rpc := os.Getenv("SEPOLIA_RPC")
	if rpc == "" {
		rpc = "https://ethereum-sepolia-rpc.publicnode.com"
	}
	outDir := "./circuit-out/il_attribution"
	srsDir := "./srs-cache"
	must(os.MkdirAll(outDir, 0o755))
	must(os.MkdirAll(srsDir, 0o755))

	// 1. Read live on-chain storage.
	ec, err := ethclient.Dial(rpc)
	must(err)
	defer ec.Close()

	// PROBE MODE: find the gateway's accepted block window fast (build witness + PrepareRequest only,
	// skip the expensive prove). Set PROBE_OFFSETS="50,100,200,..." (blocks behind head).
	if probe := os.Getenv("PROBE_OFFSETS"); probe != "" {
		probeWindow(ec, rpc, outDir, probe)
		return
	}

	// Block selection: BLOCK_OFFSET env overrides; else the `finalized` tag.
	var proofBlock *big.Int
	if off := os.Getenv("BLOCK_OFFSET"); off != "" {
		head, e := ec.BlockNumber(context.Background())
		must(e)
		var o uint64
		fmt.Sscanf(off, "%d", &o)
		proofBlock = new(big.Int).SetUint64(head - o)
		fmt.Printf("Proving Sepolia block %s (head %d - %d)\n", proofBlock, head, o)
	} else {
		finHeader, e := ec.HeaderByNumber(context.Background(), big.NewInt(int64(gethrpc.FinalizedBlockNumber)))
		must(e)
		proofBlock = finHeader.Number
		fmt.Printf("Proving Sepolia FINALIZED block %s\n", proofBlock)
	}

	slot := poolCumulativeILSlot(common.HexToHash(poolId))
	raw, err := ec.StorageAt(context.Background(), common.HexToAddress(sepHookAddr), slot, proofBlock)
	must(err)
	ilValue := new(big.Int).SetBytes(raw)
	fmt.Printf("poolCumulativeIL: %s (slot %s)\n", ilValue, slot.Hex())

	// 2. Build the BrevisApp via the proper constructor (wires ethclient + gateway).
	//    The vendored gateway client patch forces the IPv4 TLS endpoint so the gRPC
	//    connection does not reset on NAT64/IPv6 networks.
	fmt.Println("Connecting to Brevis gateway + wiring ethclient...")
	// 4th arg avoids the upstream variadic panic (gatewayUrlOverride[0] on empty args);
	// our vendored NewGatewayClient patch ignores the URL and always dials IPv4 TLS.
	app, err := sdk.NewBrevisApp(srcChainId, rpc, outDir, "appsdkv3.brevis.network:443")
	must(err)
	fmt.Println("Gateway connected, circuit digests fetched.")

	// 3. Register the REAL storage query (fetches the Merkle storage proof from Sepolia).
	app.AddStorage(sdk.StorageData{
		BlockNum: proofBlock,
		Address:  common.HexToAddress(sepHookAddr),
		Slot:     slot,
	})

	appCircuit := &ILAttributionCircuit{}
	circuitInput, err := app.BuildCircuitInput(appCircuit)
	must(err)
	fmt.Println("Circuit input built from live Sepolia storage proof.")

	// 5. Compile + setup — OR load cached artifacts to skip the slow Setup so the proof
	//    completes within the Brevis gateway's block proof window. The first run compiles
	//    (~3 min) and caches pk/vk/ccs; subsequent runs load them and prove in ~10s.
	var ccs constraint.ConstraintSystem
	var pk plonk.ProvingKey
	var vk plonk.VerifyingKey
	if fileExists(outDir+"/pk") && fileExists(outDir+"/vk") && fileExists(outDir+"/compiledCircuit") {
		fmt.Println("Loading cached compiled circuit + proving key (fast path)...")
		ccs, pk, vk = loadCached(outDir)
		fmt.Println("Cached artifacts loaded; skipping Setup.")
	} else {
		fmt.Println("First run: compiling circuit + setup (~3 min, caches for next time)...")
		var vkBytes []byte
		ccs, pk, vk, vkBytes, err = sdk.Compile(appCircuit, outDir, srsDir, app)
		must(err)
		fmt.Printf("Compiled. VK keccak256: 0x%x\n", crypto.Keccak256(vkBytes))
	}

	// 6. Prove.
	fmt.Println("Generating proof...")
	w, publicWitness, err := sdk.NewFullWitness(appCircuit, circuitInput)
	must(err)
	proof, err := sdk.Prove(ccs, pk, w)
	must(err)
	must(sdk.Verify(vk, publicWitness, proof))
	fmt.Println("Proof generated and locally verified.")

	// 7. Submit to gateway (PrepareRequest via the real gateway over IPv4).
	fmt.Println("Submitting to Brevis gateway...")
	zkMode := gwproto.QueryOption_ZK_MODE
	calldata, requestId, nonce, feeValue, err := app.PrepareRequest(
		vk, w,
		srcChainId, dstChainId,
		common.HexToAddress(refundAddr),
		common.HexToAddress(brevisShimAddr),
		300_000, &zkMode, "",
	)
	must(err)
	fmt.Printf("requestId: 0x%x\n", requestId)
	fmt.Printf("nonce: %d  feeValue: %s wei\n", nonce, feeValue)
	fmt.Printf("calldata for manual BrevisRequest.sendRequest: 0x%x\n", calldata)

	must(app.SubmitProof(proof))
	fmt.Printf("\n=== Brevis proof submitted. requestId=0x%x ===\n", requestId)
	fmt.Printf("Brevis will call BrevisVerifierShim %s on Sepolia with the verified IL.\n", brevisShimAddr)
}

// probeWindow tries PrepareRequest (the call that hits the gateway's block-window check) at several
// block depths, using the cached vk + a real witness but WITHOUT the expensive prove. It prints which
// offsets the gateway accepts so we can pick a provable block.
func probeWindow(ec *ethclient.Client, rpc, outDir, offsetsCsv string) {
	head, err := ec.BlockNumber(context.Background())
	must(err)
	vk := plonk.NewVerifyingKey(ecc.BN254)
	fVk, err := os.Open(outDir + "/vk")
	must(err)
	_, err = vk.ReadFrom(fVk)
	fVk.Close()
	must(err)

	// Allow overriding the source chain/contract/slot to test e.g. mainnet-source (srcChainId=1).
	srcChain := srcChainId
	if s := os.Getenv("SRC_CHAIN_ID"); s != "" {
		fmt.Sscanf(s, "%d", &srcChain)
	}
	contractAddr := common.HexToAddress(sepHookAddr)
	if c := os.Getenv("SRC_CONTRACT"); c != "" {
		contractAddr = common.HexToAddress(c)
	}
	slot := poolCumulativeILSlot(common.HexToHash(poolId))
	if s := os.Getenv("SRC_SLOT"); s != "" {
		slot = common.HexToHash(s)
	}
	fmt.Printf("Probe config: srcChain=%d contract=%s slot=%s\n", srcChain, contractAddr.Hex(), slot.Hex())

	var offsets []uint64
	for _, s := range splitCsv(offsetsCsv) {
		var o uint64
		fmt.Sscanf(s, "%d", &o)
		offsets = append(offsets, o)
	}
	fmt.Printf("Probing gateway window (head=%d). offsets=%v\n", head, offsets)
	appCircuit := &ILAttributionCircuit{}
	for _, o := range offsets {
		blk := new(big.Int).SetUint64(head - o)
		app, err := sdk.NewBrevisApp(srcChain, rpc, outDir, "appsdkv3.brevis.network:443")
		if err != nil {
			fmt.Printf("  head-%d (blk %s): app err: %v\n", o, blk, err)
			continue
		}
		app.AddStorage(sdk.StorageData{BlockNum: blk, Address: contractAddr, Slot: slot})
		ci, err := app.BuildCircuitInput(appCircuit)
		if err != nil {
			fmt.Printf("  head-%d (blk %s): BuildCircuitInput err: %v\n", o, blk, err)
			continue
		}
		w, _, err := sdk.NewFullWitness(appCircuit, ci)
		if err != nil {
			fmt.Printf("  head-%d (blk %s): witness err: %v\n", o, blk, err)
			continue
		}
		zk := gwproto.QueryOption_ZK_MODE
		_, reqId, _, fee, err := app.PrepareRequest(vk, w, srcChain, dstChainId,
			common.HexToAddress(refundAddr), common.HexToAddress(brevisShimAddr), 300_000, &zk, "")
		if err != nil {
			fmt.Printf("  head-%d (blk %s): REJECTED: %v\n", o, blk, err)
		} else {
			fmt.Printf("  head-%d (blk %s): ACCEPTED! requestId=0x%x fee=%s\n", o, blk, reqId, fee)
		}
	}
}

func splitCsv(s string) []string {
	var out []string
	cur := ""
	for _, c := range s {
		if c == ',' {
			if cur != "" {
				out = append(out, cur)
			}
			cur = ""
		} else {
			cur += string(c)
		}
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}

func fileExists(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

// loadCached deserializes the gnark constraint system, proving key, and verifying key
// that sdk.Compile persisted, so a re-run skips the multi-minute Setup phase.
func loadCached(outDir string) (constraint.ConstraintSystem, plonk.ProvingKey, plonk.VerifyingKey) {
	ccs := plonk.NewCS(ecc.BN254)
	fCcs, err := os.Open(outDir + "/compiledCircuit")
	must(err)
	defer fCcs.Close()
	_, err = ccs.ReadFrom(fCcs)
	must(err)

	pk := plonk.NewProvingKey(ecc.BN254)
	fPk, err := os.Open(outDir + "/pk")
	must(err)
	defer fPk.Close()
	_, err = pk.UnsafeReadFrom(fPk)
	must(err)

	vk := plonk.NewVerifyingKey(ecc.BN254)
	fVk, err := os.Open(outDir + "/vk")
	must(err)
	defer fVk.Close()
	_, err = vk.ReadFrom(fVk)
	must(err)
	return ccs, pk, vk
}

func bigHex(b *big.Int) string {
	if b == nil {
		return "0x0"
	}
	return fmt.Sprintf("0x%x", b)
}

func must(err error) {
	if err != nil {
		panic(fmt.Sprintf("fatal: %v", err))
	}
}
