// Command rprobe: generic receipt-proof probe to find which block ages the Brevis gateway's
// SMT covers. Proves topic0 of one log in each given tx (no value assertions) and reports
// whether the gateway accepts the request (PrepareRequest) for that tx's block.
//
// RESOLVED (2026-06-09, docs/BREVIS_ROUTE_RESOLUTION.md): this probe was used to map the
// "1002 SMT info missing" failures. Brevis confirmed the cause - appsdkv3.brevis.network serves
// ONLY source=Ethereum Mainnet(1) -> destination=Arbitrum One(42161); Sepolia is not indexed at any
// block age. To re-run meaningfully, set SRC_CHAIN_ID=1 with mainnet tx hashes and dstChainId=42161.
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/brevis-network/brevis-sdk/sdk"
	gwproto "github.com/brevis-network/brevis-sdk/sdk/proto/gwproto"
	"github.com/consensys/gnark-crypto/ecc"
	"github.com/consensys/gnark/backend/plonk"
	"github.com/consensys/gnark/constraint"
	"github.com/ethereum/go-ethereum/common"
)

type GenericReceiptCircuit struct{}

var _ sdk.AppCircuit = &GenericReceiptCircuit{}

func (c *GenericReceiptCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	return 32, 0, 0
}

func (c *GenericReceiptCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	receipts := sdk.NewDataStream(api, in.Receipts)
	r := sdk.GetUnderlying(receipts, 0)
	api.Uint248.AssertIsEqual(r.Fields[0].IsTopic, sdk.ConstUint248(1))
	api.Uint248.AssertIsEqual(r.Fields[0].Index, sdk.ConstUint248(0))
	api.OutputUint(64, api.ToUint248(r.BlockNum))
	api.OutputBytes32(r.Fields[0].Value)
	return nil
}

const (
	srcChainId     uint64 = 11155111
	dstChainId     uint64 = 11155111
	brevisShimAddr        = "0x96cf69e916fcb17b71957c11e1e3c43a4ea9386d"
	refundAddr            = "0xDDe9D31a31d6763612C7f535f51E5dC9f830682e"
)

func main() {
	rpc := os.Getenv("SEPOLIA_RPC")
	if rpc == "" {
		rpc = "https://sepolia.drpc.org"
	}
	outDir := "./circuit-out/rprobe"
	srsDir := "./srs-cache"
	must(os.MkdirAll(outDir, 0o755))
	src := srcChainId
	if s := os.Getenv("SRC_CHAIN_ID"); s != "" {
		fmt.Sscanf(s, "%d", &src)
	}

	txs := strings.Split(os.Getenv("TX_HASHES"), ",")
	poss := strings.Split(os.Getenv("LOG_POSITIONS"), ",")
	if len(txs) == 0 || txs[0] == "" {
		panic("set TX_HASHES and LOG_POSITIONS (comma-separated)")
	}

	appCircuit := &GenericReceiptCircuit{}

	// Compile/cache the generic circuit once.
	var ccs constraint.ConstraintSystem
	var pk plonk.ProvingKey
	var vk plonk.VerifyingKey
	if exists(outDir + "/vk") {
		fmt.Println("Loading cached generic receipt circuit...")
		ccs, pk, vk = loadCached(outDir)
		_ = ccs
		_ = pk
	} else {
		// Need one app to compile; use the first tx.
		app, err := sdk.NewBrevisApp(src, rpc, outDir, "appsdkv3.brevis.network:443")
		must(err)
		var lp uint
		fmt.Sscanf(poss[0], "%d", &lp)
		app.AddReceipt(sdk.ReceiptData{TxHash: common.HexToHash(txs[0]),
			Fields: []sdk.LogFieldData{{IsTopic: true, LogPos: lp, FieldIndex: 0}}})
		_, err = app.BuildCircuitInput(appCircuit)
		must(err)
		fmt.Println("Compiling generic receipt circuit (cached SRS, ~3min)...")
		ccs, pk, vk, _, err = sdk.Compile(appCircuit, outDir, srsDir, app)
		must(err)
		fmt.Println("Compiled.")
	}
	_ = ccs
	_ = pk

	for i, tx := range txs {
		var lp uint
		fmt.Sscanf(poss[i], "%d", &lp)
		app, err := sdk.NewBrevisApp(src, rpc, outDir, "appsdkv3.brevis.network:443")
		if err != nil {
			fmt.Printf("  tx %s: app err %v\n", tx[:12], err)
			continue
		}
		app.AddReceipt(sdk.ReceiptData{TxHash: common.HexToHash(tx),
			Fields: []sdk.LogFieldData{{IsTopic: true, LogPos: lp, FieldIndex: 0}}})
		ci, err := app.BuildCircuitInput(appCircuit)
		if err != nil {
			fmt.Printf("  tx %s (logpos %d): BuildInput err: %v\n", tx[:12], lp, err)
			continue
		}
		w, _, err := sdk.NewFullWitness(appCircuit, ci)
		if err != nil {
			fmt.Printf("  tx %s: witness err: %v\n", tx[:12], err)
			continue
		}
		zk := gwproto.QueryOption_ZK_MODE
		_, reqId, _, _, err := app.PrepareRequest(vk, w, src, dstChainId,
			common.HexToAddress(refundAddr), common.HexToAddress(brevisShimAddr), 400_000, &zk, "")
		if err != nil {
			fmt.Printf("  tx %s (logpos %d): REJECTED: %v\n", tx[:12], lp, err)
		} else {
			fmt.Printf("  tx %s (logpos %d): ACCEPTED! requestId=0x%x\n", tx[:12], lp, reqId)
		}
	}
}

func exists(p string) bool { _, e := os.Stat(p); return e == nil }

func loadCached(outDir string) (constraint.ConstraintSystem, plonk.ProvingKey, plonk.VerifyingKey) {
	ccs := plonk.NewCS(ecc.BN254)
	f1, _ := os.Open(outDir + "/compiledCircuit")
	defer f1.Close()
	ccs.ReadFrom(f1)
	pk := plonk.NewProvingKey(ecc.BN254)
	f2, _ := os.Open(outDir + "/pk")
	defer f2.Close()
	pk.UnsafeReadFrom(f2)
	vk := plonk.NewVerifyingKey(ecc.BN254)
	f3, _ := os.Open(outDir + "/vk")
	defer f3.Close()
	vk.ReadFrom(f3)
	return ccs, pk, vk
}

func must(err error) {
	if err != nil {
		panic(fmt.Sprintf("fatal: %v", err))
	}
}
