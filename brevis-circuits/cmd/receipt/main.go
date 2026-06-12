// Command receipt: STRATUM Brevis ZK circuit that proves a real STRATUM EVENT (a receipt/log)
// on Sepolia, matching the proof type Brevis's own examples (quickstart, uniswap-rebate) use.
//
// It proves the hook's ReserveFunded event from the live Across cross-chain bridge fill:
//   ReserveFunded(poolId=0x96c4cc..., amount0=0, amount1=0.9995 WETH)
// i.e. a ZK attestation that STRATUM's cross-chain junior reserve was funded, emitted by the
// real hook on Sepolia.
//
// GATEWAY ROUTE (resolved 2026-06-09, see docs/BREVIS_ROUTE_RESOLUTION.md): the local Prove/Verify
// below WORKS and is the demonstrable artifact. The hosted-gateway tail (PrepareRequest/SubmitProof/
// WaitFinalProofSubmitted) does NOT work on the Sepolia->Sepolia route configured here: Brevis
// confirmed appsdkv3.brevis.network serves ONLY source=Ethereum Mainnet(1) -> destination=Arbitrum
// One(42161), so every Sepolia request returns "1002 SMT info missing". A real gateway settlement
// needs a STRATUM event on Ethereum mainnet (source) and StratumBrevisApp on Arbitrum One
// (destination, BrevisRequest 0x91540fE35a245BA83459f6410c86F1aeC309b290) - a mainnet deployment that
// is out of scope under NFR-05 (testnets only). The src/dst constants below are kept as-is so the
// local proof still binds the real on-chain Sepolia event.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/brevis-network/brevis-sdk/sdk"
	gwproto "github.com/brevis-network/brevis-sdk/sdk/proto/gwproto"
	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/plonk"
	"github.com/consensys/gnark/constraint"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"
)

// ---------------------------------------------------------------------------
// Circuit: proves the STRATUM hook's ReserveFunded event.
// ---------------------------------------------------------------------------

type ReserveFundedCircuit struct{}

var _ sdk.AppCircuit = &ReserveFundedCircuit{}

var (
	hookAddr        = sdk.ConstUint248("0xaf618609340C81c45C201740aF349631bb8ce7c1")
	reserveFundedID = sdk.ConstFromBigEndianBytes(
		common.FromHex("0xb4777bb9cfb9db37e441072f306335de8cbfb75810cf76b02c23d8e106a8aef5"))
)

func (c *ReserveFundedCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	return 32, 0, 0
}

func (c *ReserveFundedCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	receipts := sdk.NewDataStream(api, in.Receipts)
	r := sdk.GetUnderlying(receipts, 0)

	// Field 0: topic0 = event signature. Assert it is the hook's ReserveFunded event.
	api.Uint248.AssertIsEqual(r.Fields[0].Contract, hookAddr)
	api.Uint248.AssertIsEqual(r.Fields[0].IsTopic, sdk.ConstUint248(1))
	api.Uint248.AssertIsEqual(r.Fields[0].Index, sdk.ConstUint248(0))
	api.Bytes32.AssertIsEqual(r.Fields[0].Value, reserveFundedID)

	// All three fields must come from the same log (so poolId + amount bind to this event).
	api.Uint32.AssertIsEqual(r.Fields[0].LogPos, r.Fields[1].LogPos)
	api.Uint32.AssertIsEqual(r.Fields[0].LogPos, r.Fields[2].LogPos)

	// Field 1: topic1 = poolId (indexed). Field 2: data word 1 = amount1 (the funded WETH).
	api.Uint248.AssertIsEqual(r.Fields[1].IsTopic, sdk.ConstUint248(1))
	api.Uint248.AssertIsEqual(r.Fields[1].Index, sdk.ConstUint248(1))
	api.Uint248.AssertIsEqual(r.Fields[2].IsTopic, sdk.ConstUint248(0))
	api.Uint248.AssertIsEqual(r.Fields[2].Index, sdk.ConstUint248(1))

	// Outputs: block number, the proven poolId, and the proven funded amount.
	api.OutputUint(64, api.ToUint248(r.BlockNum))
	api.OutputBytes32(r.Fields[1].Value)             // poolId
	api.OutputBytes32(r.Fields[2].Value)             // amount1 (0.9995 WETH)
	return nil
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const (
	srcChainId uint64 = 11155111 // Sepolia source (where the STRATUM hook + event live)
	dstChainId uint64 = 11155111 // Sepolia destination (BrevisVerifierShim callback)

	// The live Across-fill tx whose log[4] is the hook's ReserveFunded event.
	eventTxHash = "0xb9879355bc01cf8de36a690a216fb3e9e7fc4ae07f4e8e021590894730936e7a"
	logPosInTx  = 4

	brevisShimAddr = "0x96cf69e916fcb17b71957c11e1e3c43a4ea9386d"
	refundAddr     = "0xDDe9D31a31d6763612C7f535f51E5dC9f830682e"
)

func main() {
	rpc := os.Getenv("SEPOLIA_RPC")
	if rpc == "" {
		rpc = "https://ethereum-sepolia-rpc.publicnode.com"
	}
	outDir := "./circuit-out/receipt"
	srsDir := "./srs-cache"
	must(os.MkdirAll(outDir, 0o755))

	// 4th arg avoids the upstream variadic panic; the vendored gateway patch forces IPv4 TLS.
	app, err := sdk.NewBrevisApp(srcChainId, rpc, outDir, "appsdkv3.brevis.network:443")
	must(err)
	fmt.Println("Connected to Brevis gateway (Sepolia source).")

	// Register the STRATUM ReserveFunded event as a receipt proof.
	app.AddReceipt(sdk.ReceiptData{
		TxHash: common.HexToHash(eventTxHash),
		Fields: []sdk.LogFieldData{
			{IsTopic: true, LogPos: logPosInTx, FieldIndex: 0},  // topic0 = event sig
			{IsTopic: true, LogPos: logPosInTx, FieldIndex: 1},  // topic1 = poolId
			{IsTopic: false, LogPos: logPosInTx, FieldIndex: 1}, // data[1] = amount1
		},
	})

	appCircuit := &ReserveFundedCircuit{}
	circuitInput, err := app.BuildCircuitInput(appCircuit)
	must(err)
	fmt.Println("Circuit input built from the live STRATUM ReserveFunded receipt.")

	// Compile (cache pk/vk/ccs) or load cached.
	var ccs constraint.ConstraintSystem
	var pk plonk.ProvingKey
	var vk plonk.VerifyingKey
	if exists(outDir+"/pk") && exists(outDir+"/vk") && exists(outDir+"/compiledCircuit") {
		fmt.Println("Loading cached compiled receipt circuit...")
		ccs, pk, vk = loadCached(outDir)
	} else {
		fmt.Println("Compiling receipt circuit + setup (SRS cached; ~3 min)...")
		var vkBytes []byte
		ccs, pk, vk, vkBytes, err = sdk.Compile(appCircuit, outDir, srsDir, app)
		must(err)
		fmt.Printf("Compiled. VK keccak256: 0x%x\n", crypto.Keccak256(vkBytes))
	}

	fmt.Println("Generating proof...")
	w, publicWitness, err := sdk.NewFullWitness(appCircuit, circuitInput)
	must(err)
	proof, err := sdk.Prove(ccs, pk, w)
	must(err)
	must(sdk.Verify(vk, publicWitness, proof))
	fmt.Println("Proof generated and locally verified.")

	fmt.Println("Submitting to Brevis gateway (PrepareRequest)...")
	zk := gwproto.QueryOption_ZK_MODE
	calldata, requestId, nonce, feeValue, err := app.PrepareRequest(
		vk, w, srcChainId, dstChainId,
		common.HexToAddress(refundAddr), common.HexToAddress(brevisShimAddr),
		400_000, &zk, "")
	must(err)
	fmt.Printf("requestId: 0x%x\n", requestId)
	fmt.Printf("nonce: %d  feeValue: %s wei\n", nonce, feeValue)
	fmt.Printf("calldata (BrevisRequest.sendRequest): 0x%x\n", calldata)

	must(app.SubmitProof(proof))
	fmt.Println("Proof submitted to gateway. Waiting for Brevis to post it on-chain...")
	submitTx, err := app.WaitFinalProofSubmitted(context.Background())
	must(err)
	fmt.Printf("\n=== BREVIS PROOF ON-CHAIN ===\nFinal proof submitted by Brevis: tx %s\n", submitTx)
	fmt.Printf("It calls BrevisVerifierShim %s on Sepolia with the proven ReserveFunded event.\n", brevisShimAddr)
}

func exists(p string) bool { _, e := os.Stat(p); return e == nil }

func loadCached(outDir string) (constraint.ConstraintSystem, plonk.ProvingKey, plonk.VerifyingKey) {
	ccs := plonk.NewCS(ecc.BN254)
	f1, err := os.Open(outDir + "/compiledCircuit")
	must(err)
	defer f1.Close()
	_, err = ccs.ReadFrom(f1)
	must(err)
	pk := plonk.NewProvingKey(ecc.BN254)
	f2, err := os.Open(outDir + "/pk")
	must(err)
	defer f2.Close()
	_, err = pk.UnsafeReadFrom(f2)
	must(err)
	vk := plonk.NewVerifyingKey(ecc.BN254)
	f3, err := os.Open(outDir + "/vk")
	must(err)
	defer f3.Close()
	_, err = vk.ReadFrom(f3)
	must(err)
	return ccs, pk, vk
}

func must(err error) {
	if err != nil {
		panic(fmt.Sprintf("fatal: %v", err))
	}
}
