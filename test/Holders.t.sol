// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Briefs} from "../src/Briefs.sol";
import {BriefsText} from "../src/BriefsText.sol";
import {BriefsJury} from "../src/BriefsJury.sol";
import {ImdOracle} from "../src/ImdOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRequester} from "./mocks/MockRequester.sol";

contract RevertingToken {
    function balanceOf(address) external pure returns (uint256) {
        revert("down");
    }
}

contract GasHogToken {
    function balanceOf(address) external view returns (uint256 x) {
        while (gasleft() > 1_000) x++;
    }
}

/// Holders-only cases and the settings that moved from constants into Params.
contract HoldersTest is Test {
    string constant TASK = "Write the funniest joke about dragons.";
    string constant STANDARD = "The funnier brief wins.";
    uint256 constant MIN_HOLD = 1_000 ether;

    MockERC20 imd;
    MockERC20 token; // the project token holders-only cases check
    Briefs b;
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address treasury = makeAddr("treasury");

    function setUp() public {
        vm.warp(1_790_800_000);
        imd = new MockERC20("IMD", "IMD", address(this));
        token = new MockERC20("Token", "TKN", address(this));
        MockRequester requester = new MockRequester(IERC20(address(imd)), 0.5 ether);
        BriefsJury jury = new BriefsJury(
            BriefsJury.Oracle({
                signer: vm.addr(1), requester: requester, domain: bytes32(uint256(1)), chainId: 1, hearingGas: 3_000_000
            }),
            address(this), address(0)
        );
        b = new Briefs(IERC20(address(imd)), new BriefsText(), jury, treasury, _params());
        imd.approve(address(b), type(uint256).max); // the owner opens holders-only cases
        address[3] memory users = [creator, alice, bob];
        for (uint256 i; i < users.length; i++) {
            imd.transfer(users[i], 1_000_000 ether);
            vm.prank(users[i]);
            imd.approve(address(b), type(uint256).max);
        }
    }

    function _params() internal pure returns (Briefs.Params memory) {
        return Briefs.Params({
            minSeed: 10 ether,
            minFee: 1 ether,
            maxOracleFee: 0.9 ether,
            creatorBps: 1_500,
            platformBps: 500,
            panelSize: 11,
            quorum: 6,
            answerTimeout: 4 minutes,
            caseFee: 2 ether,
            minDuration: 10 minutes,
            maxDuration: 90 days,
            maxBrief: 500
        });
    }

    /// holders-only cases come from the owner (this test contract); open ones from a creator
    function _open(uint256 minHold, uint256 dur) internal returns (uint256) {
        if (minHold == 0) vm.prank(creator);
        return b.openCase(
            Briefs.CaseInput({
                title: "Case of the Week",
                task: TASK,
                standard: STANDARD,
                opening: "Opening brief",
                avatar: 1,
                seed: 100 ether,
                fee: 1 ether,
                endsAt: uint64(block.timestamp + dur),
                minHold: minHold
            })
        );
    }

    function _file(uint256 c, address who, string memory words) internal returns (uint256) {
        vm.prank(who);
        return b.fileBrief(c, words);
    }

    function _words(uint256 n) internal pure returns (string memory s) {
        bytes memory x = new bytes(n);
        for (uint256 i; i < n; i++) x[i] = "a";
        s = string(x);
    }

    // ------------------------------------------------------------ holders only

    function test_HoldersOnly_OnlyHoldersFile() public {
        b.setHolderToken(IERC20(address(token)));
        uint256 c = _open(MIN_HOLD, 1 days);
        assertEq(b.getCase(c).holdToken, address(token));
        assertEq(b.getCase(c).minHold, MIN_HOLD);

        assertFalse(b.holds(c, alice));
        vm.expectRevert(Briefs.NotHolder.selector);
        _file(c, alice, "no bag, no brief");

        token.transfer(alice, MIN_HOLD);
        token.transfer(bob, MIN_HOLD - 1);
        assertTrue(b.holds(c, alice));
        _file(c, alice, "holding exactly enough");
        vm.expectRevert(Briefs.NotHolder.selector);
        _file(c, bob, "one wei short");
    }

    function test_HoldersOnly_OnlyTheOwnerOpensThem() public {
        b.setHolderToken(IERC20(address(token)));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, creator));
        b.openCase(
            Briefs.CaseInput({
                title: "Not mine to gate",
                task: TASK,
                standard: STANDARD,
                opening: "Opening brief",
                avatar: 1,
                seed: 100 ether,
                fee: 1 ether,
                endsAt: uint64(block.timestamp + 1 days),
                minHold: MIN_HOLD
            })
        );
        assertEq(b.getCase(_open(MIN_HOLD, 1 days)).creator, address(this));
    }

    function test_HoldersOnly_OpenCasesStayOpenToAll() public {
        b.setHolderToken(IERC20(address(token)));
        uint256 c = _open(0, 1 days);
        assertEq(b.getCase(c).holdToken, address(0));
        assertTrue(b.holds(c, alice));
        _file(c, alice, "anyone can play here");
    }

    function test_HoldersOnly_NeedsAHolderToken() public {
        vm.expectRevert(Briefs.BadParams.selector);
        _open(MIN_HOLD, 1 days);
    }

    function test_HoldersOnly_OnlyOwnerSetsTheToken() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        b.setHolderToken(IERC20(address(token)));
    }

    function test_HoldersOnly_TokenIsFixedWhenTheCaseOpens() public {
        b.setHolderToken(IERC20(address(token)));
        uint256 c = _open(MIN_HOLD, 1 days);
        MockERC20 other = new MockERC20("Other", "OTH", alice); // alice holds plenty of another token
        b.setHolderToken(IERC20(address(other)));
        vm.expectRevert(Briefs.NotHolder.selector);
        _file(c, alice, "wrong bag");
        b.setHolderToken(IERC20(address(0))); // switching it off does not open running cases either
        vm.expectRevert(Briefs.NotHolder.selector);
        _file(c, alice, "still the wrong bag");
        vm.expectRevert(Briefs.BadParams.selector); // and no new holders-only cases
        _open(MIN_HOLD, 1 days);
    }

    function test_HoldersOnly_ABrokenTokenOnlyBlocksEntries() public {
        b.setHolderToken(IERC20(address(new RevertingToken())));
        uint256 c1 = _open(MIN_HOLD, 1 days);
        b.setHolderToken(IERC20(address(new GasHogToken())));
        uint256 c2 = _open(MIN_HOLD, 1 days);
        vm.expectRevert(Briefs.NotHolder.selector);
        _file(c1, alice, "token reverts");
        vm.expectRevert(Briefs.NotHolder.selector);
        _file(c2, alice, "token eats gas");
        // the case still ends and pays its opening brief
        vm.warp(block.timestamp + 1 days);
        uint256 before = imd.balanceOf(address(this));
        b.settle(c1);
        assertEq(imd.balanceOf(address(this)), before + 100 ether);
    }

    function test_HoldersOnly_CheckedAtFilingOnly() public {
        b.setHolderToken(IERC20(address(token)));
        uint256 c = _open(MIN_HOLD, 1 days);
        token.transfer(alice, MIN_HOLD);
        uint256 id = _file(c, alice, "my brief");
        vm.prank(alice);
        token.transfer(bob, MIN_HOLD); // sold the bag after filing: the brief stays on the docket
        assertEq(uint8(b.getBrief(id).status), uint8(Briefs.BriefStatus.Hearing));
        assertFalse(b.holds(c, alice));
    }

    // ------------------------------------------------------------ settings

    function test_Settings_CaseFeeChanges() public {
        Briefs.Params memory p = _params();
        p.caseFee = 5 ether;
        b.setParams(p);
        _open(0, 1 days);
        assertEq(imd.balanceOf(treasury), 5 ether);
        p.caseFee = 0; // free to open
        b.setParams(p);
        _open(0, 1 days);
        assertEq(imd.balanceOf(treasury), 5 ether);
    }

    function test_Settings_MaxBriefIsFixedPerCase() public {
        uint256 c1 = _open(0, 1 days);
        Briefs.Params memory p = _params();
        p.maxBrief = 600;
        b.setParams(p);
        uint256 c2 = _open(0, 1 days);
        assertEq(b.getCase(c1).maxBrief, 500);
        assertEq(b.getCase(c2).maxBrief, 600);

        vm.expectRevert(BriefsText.BadText.selector);
        _file(c1, alice, _words(501)); // the old case keeps its 500
        _file(c1, alice, _words(500));
        _file(c2, bob, _words(600));
        vm.expectRevert(BriefsText.BadText.selector);
        _file(c2, bob, _words(601));
    }

    function test_Settings_DurationBounds() public {
        Briefs.Params memory p = _params();
        p.minDuration = 1 hours;
        p.maxDuration = 365 days;
        b.setParams(p);
        vm.expectRevert(Briefs.BadDuration.selector);
        _open(0, 30 minutes);
        _open(0, 1 hours);
        _open(0, 200 days);
        vm.expectRevert(Briefs.BadDuration.selector);
        _open(0, 366 days);
    }

    function test_Settings_HardBounds() public {
        Briefs.Params memory p = _params();
        p.maxBrief = 601; // IMD's question limit
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p = _params();
        p.maxBrief = 99;
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p = _params();
        p.minDuration = 4 minutes;
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p = _params();
        p.maxDuration = 366 days;
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p = _params();
        p.minDuration = 1 days;
        p.maxDuration = 1 days;
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
        p = _params();
        p.caseFee = 1_001 ether;
        vm.expectRevert(Briefs.BadParams.selector);
        b.setParams(p);
    }

    function test_Settings_LongestQuestionFitsImd() public {
        BriefsText t = new BriefsText();
        string memory q = t.question(
            _words(240), _words(160), _words(600), _words(600), address(type(uint160).max), type(uint64).max
        );
        assertLe(bytes(q).length, 2_000); // ASCII here, so bytes bound characters; IMD takes up to 2,000
    }
}
