// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Briefs} from "../src/Briefs.sol";
import {BriefsText} from "../src/BriefsText.sol";
import {BriefsJury} from "../src/BriefsJury.sol";
import {ImdOracle} from "../src/ImdOracle.sol";
import {IImdRequester} from "../src/interfaces/IImdRequester.sol";
import {ImdGatewayRequester} from "../src/ImdGatewayRequester.sol";
import {IIntake} from "../src/interfaces/IIntake.sol";

/// forge script script/Deploy.s.sol --rpc-url https://rpc.mainnet.chain.robinhood.com --account deployer --broadcast
/// Env:
///   IMD              IMD on the target chain; default on Robinhood Chain (4663): 0x5F7Bb59365ce557C26dbcaa4EE9d39A4b95B7127
///   IMD_GATEWAY      IMD's Intake; default on Robinhood Chain: 0x1397434cd35e8a9c8ac312a61d3a285eb31dea56.
///                    The script deploys our ImdGatewayRequester on it (action IMD_ACTION; the price is read from the
///                    Intake; answers come back to the jury) and names Briefs as its only client. Run the keeper with IMD_GATEWAY set to the same address
///   IMD_ACTION       default oracle.request at oracle-1 (as bytes32)
///   IMD_REQUESTER    instead of a gateway: any other IImdRequester (tests, relays)
///   IMD_CHAIN_ID     the chain id IMD's requests carry and its attestations sign; default 1 (what IMD signs today)
///   IMD_ATTESTER     default: the live attester listed at api.imd.fun/oracle/requests
///   IMD_PINNED_DOMAIN    0 (default): every request names the jury (BriefsJury) as its EIP-712 `consumer`, so IMD
///                        signs for {chainId: this chain, verifyingContract: jury}. 1: requests carry no consumer and answers
///                        are checked against the fixed domain below (IMD's default, chainId 1 and 0x0)
///   IMD_DOMAIN_CONTRACT  with IMD_PINNED_DOMAIN=1: verifyingContract of that domain, default 0x0
///   IMD_DOMAIN_CHAIN     with IMD_PINNED_DOMAIN=1: chainId of that domain, default IMD_CHAIN_ID
///   TREASURY         receives the platform's share and the case-opening fees; default: the deployer
///   HEARING_GAS      gas each hearing gets for opening; default 3,000,000 (about 265k used on the Intake), at most 4,000,000
///   NEW_OWNER        optional, e.g. a Safe: the script starts the two-step handover of Briefs, BriefsJury and the
///                    adapter to it. Nothing changes until NEW_OWNER calls acceptOwnership() on each of the three
/// Holders-only cases need a holder token: setHolderToken(token) after deploy (none at launch).
/// Every number below can be changed later with setParams (within the contract's bounds); new numbers apply to
/// new cases only: a running case keeps its split, jury reserve, panel, answer window and brief length.
contract Deploy is Script {
    address constant IMD_ETHEREUM = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant DEFAULT_ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    uint256 constant ROBINHOOD = 4663;
    address constant IMD_ROBINHOOD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address constant GATEWAY_ROBINHOOD = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;

    function run() external {
        address imd = block.chainid == 1
            ? vm.envOr("IMD", IMD_ETHEREUM)
            : block.chainid == ROBINHOOD ? vm.envOr("IMD", IMD_ROBINHOOD) : vm.envAddress("IMD");
        address gateway = vm.envOr("IMD_GATEWAY", block.chainid == ROBINHOOD ? GATEWAY_ROBINHOOD : address(0));
        uint64 imdChain = uint64(vm.envOr("IMD_CHAIN_ID", uint256(1)));
        // with a callback, IMD signs answers for the callback target (the jury): a pinned domain would refuse them all
        require(gateway == address(0) || vm.envOr("IMD_PINNED_DOMAIN", uint256(0)) == 0, "no pinned domain with the Intake");

        vm.startBroadcast();
        ImdGatewayRequester adapter;
        IImdRequester requester;
        if (gateway != address(0)) {
            adapter = new ImdGatewayRequester(
                IIntake(gateway), IERC20(imd), vm.envOr("IMD_ACTION", bytes32("oracle.request@oracle-1")), msg.sender
            );
            requester = adapter;
        } else {
            requester = IImdRequester(vm.envAddress("IMD_REQUESTER"));
        }
        BriefsJury.Oracle memory oracle = BriefsJury.Oracle({
            signer: vm.envOr("IMD_ATTESTER", DEFAULT_ATTESTER),
            requester: requester,
            domain: vm.envOr("IMD_PINNED_DOMAIN", uint256(0)) == 1
                ? ImdOracle.domainSeparatorV(
                    "2", vm.envOr("IMD_DOMAIN_CHAIN", uint256(imdChain)), vm.envOr("IMD_DOMAIN_CONTRACT", address(0))
                )
                : bytes32(0),
            chainId: imdChain,
            hearingGas: uint32(vm.envOr("HEARING_GAS", uint256(3_000_000))) // gas each hearing gets for opening (about 265k used on the Intake)
        });
        Briefs.Params memory p = Briefs.Params({
            minSeed: 10 ether,
            minFee: 1 ether,
            maxOracleFee: 0.9 ether, // a case's jury reserve: a hearing that would cost more is skipped and refunded (0.5 today)
            creatorBps: 1_500, // 15% of every entry after the jury fee
            platformBps: 500, // 5%; the pot gets 80%
            panelSize: 11, // odd panel, simple majority: one side always reaches 6, so the jury never splits
            quorum: 6,
            answerTimeout: 4 minutes, // the swarm answered in 43–63 s in our live probe; this only covers outages
            caseFee: 2 ether, // flat price of opening a case, to the treasury
            minDuration: 10 minutes, // how short and how long a new case may run
            maxDuration: 90 days,
            maxBrief: 500 // UTF-8 bytes per brief (at most 600: IMD's question limit)
        });

        address treasury = vm.envOr("TREASURY", msg.sender);
        BriefsText text = new BriefsText();
        // only the Briefs deployed right after the jury may bind it: nobody can bind it in between
        address next = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        BriefsJury jury = new BriefsJury(oracle, msg.sender, next);
        Briefs briefs = new Briefs(IERC20(imd), text, jury, treasury, p);
        require(address(briefs) == next && address(jury.court()) == address(briefs), "jury not bound to Briefs");
        if (address(adapter) != address(0)) adapter.setClient(address(briefs));
        address newOwner = vm.envOr("NEW_OWNER", address(0));
        if (newOwner != address(0)) {
            briefs.transferOwnership(newOwner);
            jury.transferOwnership(newOwner);
            if (address(adapter) != address(0)) adapter.transferOwnership(newOwner);
        }
        vm.stopBroadcast();
        if (newOwner != address(0)) console.log("Pending owner (must acceptOwnership on all three):", newOwner);
        if (address(adapter) != address(0)) console.log("ImdGatewayRequester", address(adapter));
        console.log("BriefsText", address(text));
        console.log("BriefsJury", address(jury));
        console.log("Briefs", address(briefs));
    }
}
