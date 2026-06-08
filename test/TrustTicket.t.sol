// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FanClubMembership} from "../contracts/FanClubMembership.sol";
import {TrustTicket} from "../contracts/TrustTicket.sol";

contract TrustTicketEligibilityHarness is TrustTicket {
    mapping(address => bool) public blocked;

    constructor(address admin) TrustTicket(admin) {}

    function setBlocked(address buyer, bool value) external {
        blocked[buyer] = value;
    }

    function _checkPurchaseEligibility(address buyer, uint256 eventId) internal view override returns (bool) {
        eventId;
        return !blocked[buyer];
    }
}

contract RejectEther {
    receive() external payable {
        revert("reject");
    }
}

contract ReenteringBuyer {
    TrustTicket public ticket;
    uint256 public tokenId;

    constructor(TrustTicket ticket_, uint256 tokenId_) {
        ticket = ticket_;
        tokenId = tokenId_;
    }

    function buy() external payable {
        ticket.purchaseResaleTicket{value: msg.value}(tokenId);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        try ticket.purchaseResaleTicket{value: 1 ether}(tokenId) {} catch {}
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

contract TrustTicketTest is Test {
    TrustTicket private trustTicket;
    FanClubMembership private fanClubMembership;

    address private admin = address(0xA11CE);
    address private organizer = address(0xB0B);
    address private otherOrganizer = address(0xB0C);
    address private buyer = address(0xCAFE);
    address private buyer2 = address(0xD00D);
    address private validator = address(0xFACE);
    address private stranger = address(0xBAD);

    uint256 private eventId;
    uint256 private tokenId;
    uint256 private primaryStart;
    uint256 private primaryEnd;
    uint256 private resaleStart;
    uint256 private resaleEnd;

    function setUp() public {
        trustTicket = new TrustTicket(admin);
        fanClubMembership = new FanClubMembership(admin);
        vm.prank(admin);
        trustTicket.addOrganizer(organizer);
        vm.prank(admin);
        trustTicket.addOrganizer(otherOrganizer);

        primaryStart = block.timestamp + 1 days;
        primaryEnd = primaryStart + 7 days;
        resaleStart = primaryStart + 1 days;
        resaleEnd = primaryEnd + 10 days;

        eventId = _createDefaultEvent();
        vm.prank(organizer);
        tokenId = trustTicket.mintTicket(eventId, "A-1");

        vm.deal(buyer, 100 ether);
        vm.deal(buyer2, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    function testOrganizerCreatesEventAndMintsTickets() public view {
        TrustTicket.EventInfo memory eventInfo = trustTicket.getEventInfo(eventId);
        assertEq(eventInfo.eventId, eventId);
        assertEq(eventInfo.organizer, organizer);
        assertEq(eventInfo.eventName, "Indie Night");
        assertEq(eventInfo.totalTicketCount, 3);
        assertEq(eventInfo.remainingTicketCount, 3);
        assertTrue(eventInfo.active);
        assertFalse(eventInfo.canceled);

        TrustTicket.TicketInfo memory ticket = trustTicket.getTicketInfo(tokenId);
        assertEq(ticket.tokenId, tokenId);
        assertEq(ticket.eventId, eventId);
        assertEq(ticket.seatInfo, "A-1");
        assertEq(ticket.originalPrice, 1 ether);
        assertFalse(ticket.used);
        assertFalse(ticket.listed);
        assertEq(trustTicket.ownerOf(tokenId), address(trustTicket));

        uint256[] memory eventTickets = trustTicket.getTicketsByEvent(eventId);
        assertEq(eventTickets.length, 1);
        assertEq(eventTickets[0], tokenId);
    }

    function testOnlyAuthorizedOrganizerCanCreateAndMint() public {
        vm.prank(stranger);
        vm.expectRevert();
        trustTicket.createEvent("Nope", block.timestamp + 30 days, 1 ether, 1, primaryStart, primaryEnd, true, 12_000, resaleStart, resaleEnd);

        vm.prank(otherOrganizer);
        vm.expectRevert(TrustTicket.NotEventOrganizer.selector);
        trustTicket.mintTicket(eventId, "B-1");
    }

    function testOrganizerBurnsUnissuedTicket() public {
        vm.prank(stranger);
        vm.expectRevert(TrustTicket.NotEventOrganizer.selector);
        trustTicket.burnUnissuedTicket(tokenId);

        vm.prank(organizer);
        trustTicket.burnUnissuedTicket(tokenId);

        TrustTicket.EventInfo memory eventInfo = trustTicket.getEventInfo(eventId);
        assertEq(eventInfo.totalTicketCount, 2);
        assertEq(eventInfo.remainingTicketCount, 2);

        uint256[] memory eventTickets = trustTicket.getTicketsByEvent(eventId);
        assertEq(eventTickets.length, 0);

        vm.expectRevert(TrustTicket.TicketUnavailable.selector);
        trustTicket.getTicketInfo(tokenId);

        vm.warp(primaryStart);
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.TicketUnavailable.selector);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);
    }

    function testAdminCanBurnUnissuedTicketButPurchasedTicketCannotBeBurned() public {
        vm.prank(admin);
        trustTicket.burnUnissuedTicket(tokenId);

        vm.prank(organizer);
        uint256 replacementToken = trustTicket.mintTicket(eventId, "A-2");
        _buyPrimary(buyer, replacementToken);

        vm.prank(organizer);
        vm.expectRevert(TrustTicket.TicketUnavailable.selector);
        trustTicket.burnUnissuedTicket(replacementToken);
    }

    function testPrimaryPurchaseEscrowsUntilOrganizerWithdraws() public {
        vm.warp(primaryStart);
        uint256 organizerBalanceBefore = organizer.balance;

        vm.prank(buyer);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);

        assertEq(trustTicket.ownerOf(tokenId), buyer);
        assertEq(organizer.balance, organizerBalanceBefore);
        assertEq(trustTicket.getEventEscrowBalance(eventId), 1 ether);

        TrustTicket.EventInfo memory eventInfo = trustTicket.getEventInfo(eventId);
        assertEq(eventInfo.remainingTicketCount, 2);

        vm.prank(organizer);
        vm.expectRevert(TrustTicket.SettlementNotAvailable.selector);
        trustTicket.withdrawEventRevenue(eventId);

        vm.warp(eventInfo.eventTimestamp);
        vm.prank(organizer);
        trustTicket.withdrawEventRevenue(eventId);

        assertEq(organizer.balance, organizerBalanceBefore + 1 ether);
        assertEq(trustTicket.getEventEscrowBalance(eventId), 0);
    }

    function testPrimaryPurchaseRequiresSaleWindowExactPaymentAndUnsoldTicket() public {
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.PrimarySaleClosed.selector);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);

        vm.warp(primaryStart);
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.InvalidPrice.selector);
        trustTicket.purchaseTicket{value: 0.5 ether}(tokenId);

        vm.prank(buyer);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);

        vm.prank(buyer2);
        vm.expectRevert(TrustTicket.TicketUnavailable.selector);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);
    }

    function testExternalMembershipTokenDiscountAndPresaleAccess() public {
        vm.prank(admin);
        fanClubMembership.issueMembership(buyer);

        uint256 presaleStart = block.timestamp + 12 hours;
        uint256 presaleEnd = presaleStart + 6 hours;
        vm.prank(organizer);
        trustTicket.setMembershipPolicy(
            eventId,
            true,
            address(fanClubMembership),
            0.7 ether,
            presaleStart,
            presaleEnd,
            true
        );

        vm.warp(presaleStart);
        vm.prank(stranger);
        vm.expectRevert(TrustTicket.MembershipPassRequired.selector);
        trustTicket.purchaseTicket{value: 0.7 ether}(tokenId);

        assertTrue(trustTicket.hasMembershipPass(eventId, buyer));
        assertFalse(trustTicket.hasMembershipPass(eventId, stranger));

        vm.prank(buyer);
        trustTicket.purchaseTicket{value: 0.7 ether}(tokenId);

        assertEq(trustTicket.ownerOf(tokenId), buyer);
        assertEq(trustTicket.getEventEscrowBalance(eventId), 0.7 ether);
    }

    function testExternalMembershipTokenPublicSaleDiscount() public {
        vm.prank(admin);
        fanClubMembership.issueMembership(buyer);

        vm.prank(organizer);
        trustTicket.setMembershipPolicy(
            eventId,
            true,
            address(fanClubMembership),
            0.8 ether,
            block.timestamp + 1 hours,
            block.timestamp + 2 hours,
            true
        );

        vm.warp(primaryStart);
        vm.prank(buyer);
        trustTicket.purchaseTicket{value: 0.8 ether}(tokenId);

        assertEq(trustTicket.getEventEscrowBalance(eventId), 0.8 ether);
    }

    function testMembershipPolicyRejectsNonContractToken() public {
        vm.prank(organizer);
        vm.expectRevert(TrustTicket.InvalidMembershipToken.selector);
        trustTicket.setMembershipPolicy(eventId, true, stranger, 0.8 ether, block.timestamp + 1 hours, block.timestamp + 2 hours, true);
    }

    function testMembershipTokenCannotBeTransferred() public {
        vm.prank(admin);
        fanClubMembership.issueMembership(buyer);

        vm.prank(buyer);
        vm.expectRevert(FanClubMembership.MembershipTransferRestricted.selector);
        fanClubMembership.transferFrom(buyer, buyer2, 1);
    }

    function testListingEnforcesOwnerUnusedPeriodPolicyAndPriceCap() public {
        _buyPrimary(buyer, tokenId);

        vm.prank(stranger);
        vm.expectRevert(TrustTicket.NotTicketOwner.selector);
        trustTicket.listTicket(tokenId, 1 ether);

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.ResaleClosed.selector);
        trustTicket.listTicket(tokenId, 1 ether);

        vm.warp(resaleStart);
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.PriceCapExceeded.selector);
        trustTicket.listTicket(tokenId, 1.200000000000000001 ether);

        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.2 ether);

        assertTrue(trustTicket.isTicketListed(tokenId));
        TrustTicket.ListingInfo memory listing = trustTicket.getListingInfo(tokenId);
        assertEq(listing.seller, buyer);
        assertEq(listing.price, 1.2 ether);
        assertTrue(listing.active);
    }

    function testResalePurchaseEscrowsUntilSellerWithdraws() public {
        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.1 ether);

        uint256 sellerBalanceBefore = buyer.balance;
        vm.prank(buyer2);
        trustTicket.purchaseResaleTicket{value: 1.1 ether}(tokenId);

        assertEq(trustTicket.ownerOf(tokenId), buyer2);
        assertEq(buyer.balance, sellerBalanceBefore);
        assertEq(trustTicket.getResaleEscrowBalance(buyer), 1.1 ether);
        assertFalse(trustTicket.isTicketListed(tokenId));

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.SettlementNotAvailable.selector);
        trustTicket.withdrawResaleRevenue(tokenId);

        TrustTicket.EventInfo memory eventInfo = trustTicket.getEventInfo(eventId);
        vm.warp(eventInfo.eventTimestamp);
        vm.prank(buyer);
        trustTicket.withdrawResaleRevenue(tokenId);

        assertEq(buyer.balance, sellerBalanceBefore + 1.1 ether);
        assertEq(trustTicket.getResaleEscrowBalance(buyer), 0);
    }

    function testResalePurchaseRejectsSelfWrongPriceAndOutsidePeriod() public {
        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.1 ether);

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.SelfPurchase.selector);
        trustTicket.purchaseResaleTicket{value: 1.1 ether}(tokenId);

        vm.prank(buyer2);
        vm.expectRevert(TrustTicket.InvalidPrice.selector);
        trustTicket.purchaseResaleTicket{value: 1 ether}(tokenId);

        vm.warp(resaleEnd + 1);
        vm.prank(buyer2);
        vm.expectRevert(TrustTicket.ResaleClosed.selector);
        trustTicket.purchaseResaleTicket{value: 1.1 ether}(tokenId);
    }

    function testCanceledEventAllowsRefundBeforeWithdraw() public {
        _buyPrimary(buyer, tokenId);

        uint256 buyerBalanceBefore = buyer.balance;
        vm.prank(organizer);
        trustTicket.cancelEvent(eventId);

        vm.prank(buyer);
        trustTicket.refundTicket(tokenId);

        assertEq(buyer.balance, buyerBalanceBefore + 1 ether);
        assertEq(trustTicket.getEventEscrowBalance(eventId), 0);
        assertFalse(trustTicket.isTicketValid(tokenId));
    }

    function testCanceledEventRefundsResaleBuyerAndPrimaryBuyerBeforeWithdraw() public {
        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.1 ether);

        vm.prank(buyer2);
        trustTicket.purchaseResaleTicket{value: 1.1 ether}(tokenId);

        uint256 buyer2BalanceBefore = buyer2.balance;
        uint256 buyerBalanceBefore = buyer.balance;
        vm.prank(organizer);
        trustTicket.cancelEvent(eventId);

        vm.prank(buyer2);
        trustTicket.refundTicket(tokenId);

        assertEq(buyer2.balance, buyer2BalanceBefore + 1.1 ether);
        assertEq(buyer.balance, buyerBalanceBefore + 1 ether);
        assertEq(trustTicket.getResaleEscrowBalance(buyer), 0);
        assertEq(trustTicket.getEventEscrowBalance(eventId), 0);
    }

    function testRefundBlockedAfterOrganizerWithdraws() public {
        _buyPrimary(buyer, tokenId);
        TrustTicket.EventInfo memory eventInfo = trustTicket.getEventInfo(eventId);
        vm.warp(eventInfo.eventTimestamp);
        vm.prank(organizer);
        trustTicket.withdrawEventRevenue(eventId);

        vm.prank(organizer);
        trustTicket.cancelEvent(eventId);

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.EscrowAlreadyWithdrawn.selector);
        trustTicket.refundTicket(tokenId);
    }

    function testValidatorPermissionsAndUsedTicketRestrictions() public {
        _buyPrimary(buyer, tokenId);

        vm.prank(stranger);
        vm.expectRevert(TrustTicket.NotValidator.selector);
        trustTicket.useTicket(tokenId);

        vm.prank(organizer);
        trustTicket.addEventValidator(eventId, validator);
        vm.prank(validator);
        trustTicket.useTicket(tokenId);

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.TicketTransferRestricted.selector);
        trustTicket.transferFrom(buyer, buyer2, tokenId);

        vm.warp(resaleStart);
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.TicketUsedError.selector);
        trustTicket.listTicket(tokenId, 1 ether);
    }

    function testEligibilityHookCanBeOverriddenLater() public {
        TrustTicketEligibilityHarness harness = new TrustTicketEligibilityHarness(admin);
        vm.prank(admin);
        harness.addOrganizer(organizer);

        vm.prank(organizer);
        uint256 gatedEvent = harness.createEvent(
            "Future Gated Show",
            block.timestamp + 30 days,
            1 ether,
            1,
            primaryStart,
            primaryEnd,
            true,
            12_000,
            resaleStart,
            resaleEnd
        );
        vm.prank(organizer);
        uint256 gatedToken = harness.mintTicket(gatedEvent, "G-1");

        harness.setBlocked(buyer, true);
        vm.warp(primaryStart);
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.PurchaseNotEligible.selector);
        harness.purchaseTicket{value: 1 ether}(gatedToken);
    }

    function testSignedTicketVerificationLifecycle() public {
        uint256 buyerKey = 0xA11CE;
        address signingBuyer = vm.addr(buyerKey);
        vm.deal(signingBuyer, 10 ether);
        _buyPrimary(signingBuyer, tokenId);

        uint256 expiresAt = block.timestamp + 10 minutes;
        bytes memory signature = _signTicket(trustTicket, buyerKey, tokenId, signingBuyer, expiresAt);
        assertTrue(trustTicket.verifySignedTicket(tokenId, signingBuyer, expiresAt, signature));

        vm.prank(organizer);
        trustTicket.addEventValidator(eventId, validator);
        vm.prank(validator);
        trustTicket.useTicket(tokenId);

        assertFalse(trustTicket.verifySignedTicket(tokenId, signingBuyer, expiresAt, signature));
    }

    function testReentrancyGuardBlocksResaleReentry() public {
        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1 ether);

        ReenteringBuyer reenteringBuyer = new ReenteringBuyer(trustTicket, tokenId);
        vm.deal(address(reenteringBuyer), 10 ether);
        reenteringBuyer.buy{value: 1 ether}();

        assertEq(trustTicket.ownerOf(tokenId), address(reenteringBuyer));
        assertFalse(trustTicket.isTicketListed(tokenId));
    }

    function testWithdrawFailureReverts() public {
        RejectEther rejectingOrganizer = new RejectEther();
        vm.prank(admin);
        trustTicket.addOrganizer(address(rejectingOrganizer));

        vm.prank(address(rejectingOrganizer));
        uint256 rejectingEvent = trustTicket.createEvent(
            "Reject Show",
            block.timestamp + 30 days,
            1 ether,
            1,
            primaryStart,
            primaryEnd,
            true,
            12_000,
            resaleStart,
            resaleEnd
        );
        vm.prank(address(rejectingOrganizer));
        uint256 rejectingToken = trustTicket.mintTicket(rejectingEvent, "R-1");

        vm.warp(primaryStart);
        vm.prank(buyer);
        trustTicket.purchaseTicket{value: 1 ether}(rejectingToken);

        TrustTicket.EventInfo memory rejectingEventInfo = trustTicket.getEventInfo(rejectingEvent);
        vm.warp(rejectingEventInfo.eventTimestamp);
        vm.prank(address(rejectingOrganizer));
        vm.expectRevert(TrustTicket.PaymentTransferFailed.selector);
        trustTicket.withdrawEventRevenue(rejectingEvent);
    }

    function _createDefaultEvent() private returns (uint256) {
        vm.prank(organizer);
        return trustTicket.createEvent(
            "Indie Night",
            block.timestamp + 30 days,
            1 ether,
            3,
            primaryStart,
            primaryEnd,
            true,
            12_000,
            resaleStart,
            resaleEnd
        );
    }

    function _buyPrimary(address buyer_, uint256 tokenId_) private {
        vm.warp(primaryStart);
        vm.prank(buyer_);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId_);
    }

    function _signTicket(
        TrustTicket ticketContract,
        uint256 signerKey,
        uint256 tokenId_,
        address claimedOwner,
        uint256 expiresAt
    ) private view returns (bytes memory) {
        bytes32 messageHash = ticketContract.getTicketCheckInMessageHash(tokenId_, claimedOwner, expiresAt);
        bytes32 ethSignedMessageHash = _toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _toEthSignedMessageHash(bytes32 messageHash) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
    }
}
