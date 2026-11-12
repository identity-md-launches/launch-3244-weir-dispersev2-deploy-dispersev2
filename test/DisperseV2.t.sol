// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {DisperseV2} from "../src/DisperseV2.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PlainToken} from "./mocks/PlainToken.sol";
import {NoReturnToken} from "./mocks/NoReturnToken.sol";
import {DeployV2} from "../script/DeployV2.s.sol";

/// @dev Refuses one recipient with a custom error, like a frozen or blocklisted address on a real stablecoin.
contract FreezingToken is ERC20 {
    error Frozen(address account);

    mapping(address => bool) public frozen;

    constructor() ERC20("Freezing", "FRZ") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function freeze(address account) external {
        frozen[account] = true;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen[to]) revert Frozen(to);
        super._update(from, to, value);
    }
}

/// @dev Answers `transferFrom` however the test tells it to, and always reports a full allowance.
contract OddToken {
    enum Mode {
        ReturnFalse,
        ReturnOneByte,
        ReturnTwo,
        RevertHuge,
        RevertEmpty,
        ReturnTrueLong
    }

    Mode public mode;

    function set(Mode m) external {
        mode = m;
    }

    function allowance(address, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function transferFrom(address, address, uint256) external view {
        Mode m = mode;
        assembly {
            switch m
            case 0 {
                mstore(0, 0)
                return(0, 32)
            }
            case 1 {
                mstore8(0, 1)
                return(0, 1)
            }
            case 2 {
                mstore(0, 2)
                return(0, 32)
            }
            case 3 {
                // 20,000 bytes of 0xff: a token trying to make the caller pay to copy its answer.
                let p := mload(0x40)
                for { let i := 0 } lt(i, 20000) { i := add(i, 32) } { mstore(add(p, i), not(0)) }
                revert(p, 20000)
            }
            case 4 { revert(0, 0) }
            default {
                // `true` followed by another word: still a yes.
                mstore(0, 1)
                mstore(32, 7)
                return(0, 64)
            }
        }
    }
}

/// @dev On every transferFrom it tries to pay itself out of a victim's standing approval, through each entry point.
contract ThievingToken is ERC20 {
    DisperseV2 internal d;
    IERC20 internal loot;
    bool internal busy;
    uint256 public attempts;
    uint256 public successes;

    constructor(DisperseV2 d_, IERC20 loot_) ERC20("Thief", "THF") {
        d = d_;
        loot = loot_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (!busy) {
            busy = true;
            address[] memory who = new address[](1);
            uint256[] memory amts = new uint256[](1);
            who[0] = address(0xBEEF);
            amts[0] = 1e6;
            string[] memory none = new string[](0);
            DisperseV2.Permit memory p;
            attempts += 2;
            try d.disperse(loot, who, amts) {
                successes++;
            } catch {}
            try d.disperseWithMemo(loot, who, amts, bytes32(uint256(1)), "mine", none, p) {
                successes++;
            } catch {}
            busy = false;
        }
        return super.transferFrom(from, to, amount);
    }
}

contract DisperseV2Test is Test {
    DisperseV2 internal d;
    MockUSDC internal usdc;

    uint256 internal senderKey = 0xA11CE;
    address internal sender;
    address internal a = makeAddr("a");
    address internal b = makeAddr("b");
    address internal c = makeAddr("c");

    bytes32 internal constant REF = keccak256("payout-1");
    DisperseV2.Permit internal noPermit;

    event Dispersed(address indexed sender, address indexed token, uint256 total, uint256 count);
    event Memo(
        address indexed sender, address indexed token, bytes32 indexed ref, uint256 total, uint256 count, string memo
    );
    event Paid(
        address indexed sender, address indexed to, address indexed token, uint256 amount, bytes32 ref, string memo
    );

    function setUp() public {
        d = new DisperseV2();
        usdc = new MockUSDC();
        sender = vm.addr(senderKey);
        usdc.mint(sender, 1_000_000e6);
    }

    function _three() internal view returns (address[] memory to, uint256[] memory amts) {
        to = new address[](3);
        amts = new uint256[](3);
        to[0] = a;
        to[1] = b;
        to[2] = c;
        amts[0] = 100e6;
        amts[1] = 250e6;
        amts[2] = 1;
    }

    function _memos(string memory x, string memory y, string memory z) internal pure returns (string[] memory m) {
        m = new string[](3);
        m[0] = x;
        m[1] = y;
        m[2] = z;
    }

    function _none() internal pure returns (string[] memory m) {
        m = new string[](0);
    }

    function _bytes(uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = "x";
        }
        return string(out);
    }

    function _permitSig(uint256 key, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (DisperseV2.Permit memory p)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(d),
                value,
                usdc.nonces(owner),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        p = DisperseV2.Permit(deadline, v, r, s);
    }

    // ---- memo: what is emitted --------------------------------------------------------------------

    function test_memo_payoutMemoAndRef() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), 350e6 + 1);
        vm.expectEmit(true, true, false, true, address(d));
        emit Dispersed(sender, address(usdc), 350e6 + 1, 3);
        vm.expectEmit(true, true, true, true, address(d));
        emit Memo(sender, address(usdc), REF, 350e6 + 1, 3, "October bounties");
        d.disperseWithMemo(usdc, to, amts, REF, "October bounties", _none(), noPermit);
        vm.stopPrank();

        assertEq(usdc.balanceOf(a), 100e6);
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.balanceOf(c), 1);
        assertEq(usdc.allowance(sender, address(d)), 0);
        assertEq(usdc.balanceOf(address(d)), 0);
    }

    function test_memo_refOnly_andMemoOnly_eachEmitMemo() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), 2 * (350e6 + 1));
        vm.expectEmit(true, true, true, true, address(d));
        emit Memo(sender, address(usdc), REF, 350e6 + 1, 3, "");
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), noPermit);
        vm.expectEmit(true, true, true, true, address(d));
        emit Memo(sender, address(usdc), bytes32(0), 350e6 + 1, 3, "thanks");
        d.disperseWithMemo(usdc, to, amts, bytes32(0), "thanks", _none(), noPermit);
        vm.stopPrank();
    }

    function test_memo_nothingGiven_emitsOnlyDispersed() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), 350e6 + 1);
        vm.recordLogs();
        d.disperseWithMemo(usdc, to, amts, bytes32(0), "", _none(), noPermit);
        vm.stopPrank();
        // 3 token Transfer logs + 1 Dispersed, and nothing else.
        assertEq(vm.getRecordedLogs().length, 4);
        assertEq(usdc.balanceOf(b), 250e6);
    }

    function test_memo_perRecipient_emitsPaidOnlyForNonEmpty() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), 350e6 + 1);
        vm.expectEmit(true, true, true, true, address(d));
        emit Paid(sender, a, address(usdc), 100e6, REF, "first place");
        vm.expectEmit(true, true, true, true, address(d));
        emit Paid(sender, c, address(usdc), 1, REF, unicode"merci 🐸");
        vm.recordLogs();
        d.disperseWithMemo(usdc, to, amts, REF, "", _memos("first place", "", unicode"merci 🐸"), noPermit);
        vm.stopPrank();
        // 3 Transfers, 2 Paid (b's memo is empty), 1 Dispersed, 1 Memo (the ref).
        assertEq(vm.getRecordedLogs().length, 7);
        assertEq(usdc.balanceOf(a), 100e6);
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.balanceOf(c), 1);
    }

    function test_memo_arbitraryBytesAreCarriedExactly() public {
        (address[] memory to, uint256[] memory amts) = _three();
        // Not valid UTF-8, and shaped like a call to transferFrom: it is only ever data.
        string memory odd = string(
            abi.encodePacked(hex"ff00fe", abi.encodeCall(IERC20.transferFrom, (sender, address(this), 999_999e6)))
        );
        vm.startPrank(sender);
        usdc.approve(address(d), type(uint256).max);
        vm.expectEmit(true, true, true, true, address(d));
        emit Paid(sender, b, address(usdc), 250e6, bytes32(0), odd);
        vm.expectEmit(true, true, true, true, address(d));
        emit Memo(sender, address(usdc), bytes32(0), 350e6 + 1, 3, odd);
        d.disperseWithMemo(usdc, to, amts, bytes32(0), odd, _memos("", odd, ""), noPermit);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(this)), 0);
        assertEq(usdc.balanceOf(sender), 1_000_000e6 - 350e6 - 1);
    }

    function testFuzz_memo_neverChangesWhoIsPaid(bytes calldata memo, bytes calldata rowMemo, bytes32 ref) public {
        vm.assume(memo.length <= 280 && rowMemo.length <= 140);
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), 350e6 + 1);
        d.disperseWithMemo(usdc, to, amts, ref, string(memo), _memos(string(rowMemo), "", string(rowMemo)), noPermit);
        vm.stopPrank();
        assertEq(usdc.balanceOf(a), 100e6);
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.balanceOf(c), 1);
        assertEq(usdc.balanceOf(sender), 1_000_000e6 - 350e6 - 1);
        assertEq(usdc.balanceOf(address(d)), 0);
        assertEq(usdc.allowance(sender, address(d)), 0);
    }

    // ---- memo: limits -----------------------------------------------------------------------------

    function test_memo_lengthLimits_atAndOverTheBoundary() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), type(uint256).max);
        d.disperseWithMemo(usdc, to, amts, REF, _bytes(280), _memos(_bytes(140), "", _bytes(140)), noPermit);

        vm.expectRevert(abi.encodeWithSelector(DisperseV2.MemoTooLong.selector, type(uint256).max));
        d.disperseWithMemo(usdc, to, amts, REF, _bytes(281), _none(), noPermit);

        vm.expectRevert(abi.encodeWithSelector(DisperseV2.MemoTooLong.selector, 2));
        d.disperseWithMemo(usdc, to, amts, REF, "", _memos("", "", _bytes(141)), noPermit);
        vm.stopPrank();
        assertEq(d.MAX_MEMO_BYTES(), 280);
        assertEq(d.MAX_ROW_MEMO_BYTES(), 140);
    }

    function test_memo_revert_wrongNumberOfRowMemos() public {
        (address[] memory to, uint256[] memory amts) = _three();
        string[] memory two = new string[](2);
        string[] memory four = new string[](4);
        vm.startPrank(sender);
        usdc.approve(address(d), type(uint256).max);
        vm.expectRevert(DisperseV2.MemoLengthMismatch.selector);
        d.disperseWithMemo(usdc, to, amts, REF, "", two, noPermit);
        vm.expectRevert(DisperseV2.MemoLengthMismatch.selector);
        d.disperseWithMemo(usdc, to, amts, REF, "", four, noPermit);
        vm.stopPrank();
        assertEq(usdc.balanceOf(a), 0);
    }

    function test_memo_sameInputChecksAsDisperse() public {
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        usdc.approve(address(d), type(uint256).max);

        to[1] = address(0);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.ZeroRecipient.selector, 1));
        d.disperseWithMemo(usdc, to, amts, REF, "m", _none(), noPermit);

        to[1] = address(d);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.SelfRecipient.selector, 1));
        d.disperseWithMemo(usdc, to, amts, REF, "m", _none(), noPermit);

        to[1] = address(usdc);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.SelfRecipient.selector, 1));
        d.disperseWithMemo(usdc, to, amts, REF, "m", _none(), noPermit);

        to[1] = b;
        amts[2] = 0;
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.ZeroAmount.selector, 2));
        d.disperseWithMemo(usdc, to, amts, REF, "m", _none(), noPermit);

        vm.expectRevert(DisperseV2.Empty.selector);
        d.disperseWithMemo(usdc, new address[](0), new uint256[](0), REF, "m", _none(), noPermit);

        vm.expectRevert(DisperseV2.LengthMismatch.selector);
        d.disperseWithMemo(usdc, to, new uint256[](2), REF, "m", _none(), noPermit);
        vm.stopPrank();
    }

    function test_tokenAsRecipient_refusedByEveryEntryPoint() public {
        (address[] memory to, uint256[] memory amts) = _three();
        to[2] = address(usdc);
        DisperseV2.Permit memory p = _permitSig(senderKey, sender, 350e6 + 1, block.timestamp + 1 hours);
        bytes memory refused = abi.encodeWithSelector(DisperseV2.SelfRecipient.selector, 2);
        vm.startPrank(sender);
        usdc.approve(address(d), type(uint256).max);
        vm.expectRevert(refused);
        d.disperse(usdc, to, amts);
        vm.expectRevert(refused);
        d.disperseWithPermit(usdc, to, amts, p.deadline, p.v, p.r, p.s);
        vm.expectRevert(refused);
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), p);
        vm.stopPrank();
        // sumOf has no token to compare with (v1's signature): it still returns the sum.
        assertEq(d.sumOf(to, amts), 350e6 + 1);
        assertEq(usdc.balanceOf(address(usdc)), 0);
    }

    // ---- a refused transfer names its row -------------------------------------------------------------

    function test_refused_frozenRecipient_namesTheRow_andMovesNothing() public {
        FreezingToken t = new FreezingToken();
        t.mint(sender, 1_000e6);
        t.freeze(c);
        (address[] memory to, uint256[] memory amts) = _three();
        bytes memory expected = abi.encodeWithSelector(
            DisperseV2.TransferFailed.selector, 2, abi.encodeWithSelector(FreezingToken.Frozen.selector, c)
        );
        vm.startPrank(sender);
        t.approve(address(d), 350e6 + 1);
        vm.expectRevert(expected);
        d.disperse(IERC20(address(t)), to, amts);
        vm.expectRevert(expected);
        d.disperseWithMemo(IERC20(address(t)), to, amts, REF, "m", _memos("x", "y", "z"), noPermit);
        vm.stopPrank();
        assertEq(t.balanceOf(a), 0);
        assertEq(t.balanceOf(b), 0);
        assertEq(t.balanceOf(sender), 1_000e6);
        assertEq(t.allowance(sender, address(d)), 350e6 + 1);
    }

    function test_refused_oddAnswersFromTheToken() public {
        OddToken t = new OddToken();
        (address[] memory to, uint256[] memory amts) = _three();

        t.set(OddToken.Mode.ReturnFalse);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.TransferFailed.selector, 0, abi.encode(uint256(0))));
        d.disperse(IERC20(address(t)), to, amts);

        t.set(OddToken.Mode.ReturnOneByte);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.TransferFailed.selector, 0, hex"01"));
        d.disperse(IERC20(address(t)), to, amts);

        t.set(OddToken.Mode.ReturnTwo);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.TransferFailed.selector, 0, abi.encode(uint256(2))));
        d.disperse(IERC20(address(t)), to, amts);

        t.set(OddToken.Mode.RevertEmpty);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.TransferFailed.selector, 0, ""));
        d.disperse(IERC20(address(t)), to, amts);

        // `true` with more data after it is still a yes.
        t.set(OddToken.Mode.ReturnTrueLong);
        d.disperse(IERC20(address(t)), to, amts);
    }

    function test_refused_hugeRevertDataIsCutTo256Bytes() public {
        OddToken t = new OddToken();
        t.set(OddToken.Mode.RevertHuge);
        (address[] memory to, uint256[] memory amts) = _three();
        bytes memory cut = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            cut[i] = 0xff;
        }
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.TransferFailed.selector, 0, cut));
        d.disperse(IERC20(address(t)), to, amts);
    }

    function test_refused_plainTokenShortBalance_inMemoPath() public {
        PlainToken t = new PlainToken();
        t.mint(sender, 100e6);
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        t.approve(address(d), 350e6 + 1);
        vm.expectPartialRevert(DisperseV2.TransferFailed.selector);
        d.disperseWithMemo(IERC20(address(t)), to, amts, REF, "m", _none(), noPermit);
        vm.stopPrank();
        assertEq(t.balanceOf(a), 0);
    }

    // ---- permit inside disperseWithMemo ---------------------------------------------------------------

    function test_memoPermit_happy() public {
        (address[] memory to, uint256[] memory amts) = _three();
        DisperseV2.Permit memory p = _permitSig(senderKey, sender, 350e6 + 1, block.timestamp + 20 minutes);
        vm.prank(sender);
        d.disperseWithMemo(usdc, to, amts, REF, "with a permit", _memos("a", "b", "c"), p);
        assertEq(usdc.balanceOf(a), 100e6);
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.balanceOf(c), 1);
        assertEq(usdc.allowance(sender, address(d)), 0);
        assertEq(usdc.nonces(sender), 1);
    }

    function test_memoPermit_frontRunStillSucceeds() public {
        (address[] memory to, uint256[] memory amts) = _three();
        DisperseV2.Permit memory p = _permitSig(senderKey, sender, 350e6 + 1, block.timestamp + 20 minutes);
        // Someone replays the signature first.
        usdc.permit(sender, address(d), 350e6 + 1, p.deadline, p.v, p.r, p.s);
        vm.prank(sender);
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), p);
        assertEq(usdc.balanceOf(b), 250e6);
    }

    function test_memoPermit_expired_bubblesTheTokensReason() public {
        (address[] memory to, uint256[] memory amts) = _three();
        uint256 deadline = block.timestamp + 1;
        DisperseV2.Permit memory p = _permitSig(senderKey, sender, 350e6 + 1, deadline);
        vm.warp(deadline + 1);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), p);
    }

    function test_memoPermit_zeroDeadlineMeansNoPermit() public {
        (address[] memory to, uint256[] memory amts) = _three();
        // A full signature is ignored when the deadline is zero: the allowance is the only gate.
        DisperseV2.Permit memory p = _permitSig(senderKey, sender, 350e6 + 1, block.timestamp + 20 minutes);
        p.deadline = 0;
        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.InsufficientAllowance.selector, 350e6 + 1, 0));
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), p);
        usdc.approve(address(d), 350e6 + 1);
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), p);
        vm.stopPrank();
        assertEq(usdc.nonces(sender), 0);
        assertEq(usdc.balanceOf(b), 250e6);
    }

    function test_memoPermit_tokenWithoutPermit_fallsBackToAllowance() public {
        PlainToken t = new PlainToken();
        t.mint(sender, 1_000e6);
        (address[] memory to, uint256[] memory amts) = _three();
        DisperseV2.Permit memory p =
            DisperseV2.Permit(block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.InsufficientAllowance.selector, 350e6 + 1, 0));
        d.disperseWithMemo(IERC20(address(t)), to, amts, REF, "", _none(), p);
        t.approve(address(d), 350e6 + 1);
        d.disperseWithMemo(IERC20(address(t)), to, amts, REF, "", _none(), p);
        vm.stopPrank();
        assertEq(t.balanceOf(b), 250e6);
    }

    // ---- only the caller's tokens ever move -----------------------------------------------------------

    function test_thirdPartyAllowance_unusableThroughMemoPath() public {
        // The victim leaves an unlimited approval on the contract and has signed a permit for it too.
        vm.prank(sender);
        usdc.approve(address(d), type(uint256).max);
        DisperseV2.Permit memory victims = _permitSig(senderKey, sender, 100e6, block.timestamp + 1 hours);

        address attacker = makeAddr("attacker");
        address[] memory to = new address[](1);
        uint256[] memory amts = new uint256[](1);
        to[0] = attacker;
        amts[0] = 100e6;

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(DisperseV2.InsufficientAllowance.selector, 100e6, 0));
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), noPermit);
        // The victim's signature names the victim as owner; the contract asks for the caller as owner.
        vm.expectPartialRevert(ERC20Permit.ERC2612InvalidSigner.selector);
        d.disperseWithMemo(usdc, to, amts, REF, "", _none(), victims);
        vm.stopPrank();
        assertEq(usdc.balanceOf(attacker), 0);
        assertEq(usdc.balanceOf(sender), 1_000_000e6);
    }

    function test_reentrantToken_cannotSpendAVictimsApproval() public {
        address victim = makeAddr("victim");
        usdc.mint(victim, 500e6);
        vm.prank(victim);
        usdc.approve(address(d), type(uint256).max);

        ThievingToken evil = new ThievingToken(d, usdc);
        evil.mint(sender, 1_000e6);
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        evil.approve(address(d), type(uint256).max);
        d.disperseWithMemo(IERC20(address(evil)), to, amts, REF, "m", _memos("x", "y", "z"), noPermit);
        vm.stopPrank();

        assertEq(evil.attempts(), 6);
        assertEq(evil.successes(), 0);
        assertEq(usdc.balanceOf(victim), 500e6);
        assertEq(usdc.balanceOf(address(0xBEEF)), 0);
        assertEq(evil.balanceOf(b), 250e6);
    }

    function test_noEthAccepted() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(d).call{value: 1}("");
        assertFalse(ok);
        (address[] memory to, uint256[] memory amts) = _three();
        (ok,) = address(d).call{value: 1}(abi.encodeCall(d.disperse, (usdc, to, amts)));
        assertFalse(ok);
        assertEq(address(d).balance, 0);
    }

    // ---- what a failing row does and does not tell you ----------------------------------------------------

    /// @dev The row named is where the transfer failed, not whose fault it is: a balance that covers only the first
    ///      row names row 1, though nothing is wrong with that recipient.
    function test_refused_shortBalance_namesTheRowWhereMoneyRanOut() public {
        address poor = makeAddr("poor");
        usdc.mint(poor, 100e6);
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(poor);
        usdc.approve(address(d), type(uint256).max);
        vm.expectPartialRevert(DisperseV2.TransferFailed.selector);
        d.disperse(usdc, to, amts);
        (bool ok, bytes memory ret) = address(d).call(abi.encodeCall(d.disperse, (usdc, to, amts)));
        vm.stopPrank();
        assertFalse(ok);
        uint256 index;
        assembly {
            index := mload(add(ret, 36))
        }
        assertEq(index, 1);
        assertEq(usdc.balanceOf(a), 0);
        assertEq(usdc.balanceOf(poor), 100e6);
    }

    function test_refused_onlyTheFirstBadRowIsNamed() public {
        FreezingToken t = new FreezingToken();
        t.mint(sender, 1_000e6);
        t.freeze(b);
        t.freeze(c);
        (address[] memory to, uint256[] memory amts) = _three();
        vm.startPrank(sender);
        t.approve(address(d), 350e6 + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                DisperseV2.TransferFailed.selector, 1, abi.encodeWithSelector(FreezingToken.Frozen.selector, b)
            )
        );
        d.disperseWithMemo(IERC20(address(t)), to, amts, REF, "", _none(), noPermit);
        vm.stopPrank();
        assertEq(t.balanceOf(a), 0);
    }

    // ---- more shapes through the memo path ----------------------------------------------------------------

    function test_memo_noReturnToken_oneRecipient_andDuplicates() public {
        NoReturnToken t = new NoReturnToken();
        t.mint(sender, 1_000e6);
        address[] memory one = new address[](1);
        uint256[] memory amt = new uint256[](1);
        one[0] = a;
        amt[0] = 7e6;
        string[] memory m = new string[](1);
        m[0] = "only you";
        vm.startPrank(sender);
        t.approve(address(d), 7e6);
        vm.expectEmit(true, true, true, true, address(d));
        emit Paid(sender, a, address(t), 7e6, REF, "only you");
        vm.expectEmit(true, true, true, true, address(d));
        emit Memo(sender, address(t), REF, 7e6, 1, "");
        d.disperseWithMemo(IERC20(address(t)), one, amt, REF, "", m, noPermit);
        vm.stopPrank();
        assertEq(t.balanceOf(a), 7e6);

        // The same wallet twice is two rows, two payments and two notes.
        address[] memory twice = new address[](2);
        uint256[] memory amts = new uint256[](2);
        twice[0] = b;
        twice[1] = b;
        amts[0] = 1e6;
        amts[1] = 2e6;
        string[] memory notes = new string[](2);
        notes[0] = "one";
        notes[1] = "two";
        vm.startPrank(sender);
        usdc.approve(address(d), 3e6);
        vm.recordLogs();
        d.disperseWithMemo(usdc, twice, amts, REF, "", notes, noPermit);
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 6); // 2 Transfer, 2 Paid, Dispersed, Memo
        assertEq(usdc.balanceOf(b), 3e6);
    }

    /// @dev Calldata that lies about where a memo is or how long it is must revert or change nothing about payment.
    function test_memo_malformedCalldata_neverChangesAPayment() public {
        (address[] memory to, uint256[] memory amts) = _three();
        bytes memory good =
            abi.encodeCall(d.disperseWithMemo, (usdc, to, amts, REF, "m", _memos("x", "y", "z"), noPermit));
        vm.startPrank(sender);
        usdc.approve(address(d), type(uint256).max);

        // The `memos` head word (7th argument: offset 4 + 5 * 32) pointed far outside the calldata.
        bytes memory bad = bytes.concat(good);
        assembly {
            mstore(add(bad, add(32, add(4, mul(5, 32)))), 0xffffffff)
        }
        (bool ok,) = address(d).call(bad);
        assertFalse(ok);

        // The payout memo's head word (6th argument) pointed at the amounts array: whatever it reads is only a memo.
        bad = bytes.concat(good);
        bytes32 amountsOffset;
        assembly {
            amountsOffset := mload(add(bad, add(32, add(4, mul(2, 32)))))
            mstore(add(bad, add(32, add(4, mul(4, 32)))), amountsOffset)
        }
        (ok,) = address(d).call(bad);
        // amounts.length (3) is read as the memo's length: a 3-byte memo. Payments are exactly as asked.
        assertTrue(ok);
        vm.stopPrank();
        assertEq(usdc.balanceOf(a), 100e6);
        assertEq(usdc.balanceOf(b), 250e6);
        assertEq(usdc.balanceOf(c), 1);
        assertEq(usdc.balanceOf(sender), 1_000_000e6 - 350e6 - 1);
        assertEq(usdc.balanceOf(address(d)), 0);
    }

    function test_deploy_predictedAddressIsPinned() public {
        DeployV2 s = new DeployV2();
        assertEq(s.predict(), s.EXPECTED(), "bytecode drift: update DeployV2.EXPECTED, the README and the app");
    }

    // ---- gas ------------------------------------------------------------------------------------------

    function test_gas_250recipients_threeWays() public {
        uint256 n = 250;
        address[] memory to = new address[](n);
        uint256[] memory amts = new uint256[](n);
        string[] memory memos = new string[](n);
        string memory row = _bytes(140);
        // Built before the measured calls: making a 280-byte string in the test costs more than emitting it.
        string memory payout = _bytes(280);
        string[] memory none = _none();
        for (uint256 i; i < n; ++i) {
            amts[i] = 1e6;
            memos[i] = row;
        }
        vm.startPrank(sender);
        usdc.approve(address(d), type(uint256).max);

        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(0x10000 + i));
        }
        uint256 g = gasleft();
        d.disperse(usdc, to, amts);
        uint256 plain = g - gasleft();

        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(0x20000 + i));
        }
        g = gasleft();
        d.disperseWithMemo(usdc, to, amts, REF, payout, none, noPermit);
        uint256 payoutMemo = g - gasleft();

        for (uint256 i; i < n; ++i) {
            to[i] = address(uint160(0x30000 + i));
        }
        g = gasleft();
        d.disperseWithMemo(usdc, to, amts, REF, payout, memos, noPermit);
        uint256 everyRow = g - gasleft();
        vm.stopPrank();

        emit log_named_uint("250 recipients, no memo", plain);
        emit log_named_uint("250 recipients, a 280-byte payout memo", payoutMemo);
        emit log_named_uint("250 recipients, each with a 140-byte memo", everyRow);
        assertLt(payoutMemo - plain, 60_000, "a payout memo costs one event and its calldata");
        // Loose on purpose: how much of the test's own memory and warm/cold access a forge version charges to the
        // measured call differs (about 5,900 per row on forge 1.5, about 8,500 on 1.8). The hard limit is the next line.
        assertLt((everyRow - payoutMemo) / n, 20_000, "a row memo costs one event and its calldata");
        assertLt(everyRow, 16_000_000, "the heaviest case must fit in half of a 32M transaction");
    }
}
