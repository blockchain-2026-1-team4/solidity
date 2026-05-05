// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
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

    function testOrganizerCreatesEventAndMintsTickets() public {
        TrustTicket.EventInfo memory eventInfo = trustTicket.getEventInfo(eventId);
        assertEq(eventInfo.eventId, eventId);
        assertEq(eventInfo.organizer, organizer);
        assertEq(eventInfo.eventName, "Indie Night");
        assertEq(eventInfo.totalTicketCount, 3);
        assertEq(eventInfo.remainingTicketCount, 3);
        assertTrue(eventInfo.active);

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

    function testPrimaryPurchaseTransfersTicketAndPaysOrganizer() public {
        vm.warp(primaryStart);
        uint256 organizerBalanceBefore = organizer.balance;

        vm.prank(buyer);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);

        assertEq(trustTicket.ownerOf(tokenId), buyer);
        assertEq(organizer.balance, organizerBalanceBefore + 1 ether);

        TrustTicket.EventInfo memory eventInfo = trustTicket.getEventInfo(eventId);
        assertEq(eventInfo.remainingTicketCount, 2);

        uint256[] memory ownerTickets = trustTicket.getTicketsByOwner(buyer);
        assertEq(ownerTickets.length, 1);
        assertEq(ownerTickets[0], tokenId);
        assertTrue(trustTicket.isTicketValid(tokenId));
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

    function testPrimaryPurchaseAndResalePurchaseAreSeparateFlows() public {
        _buyPrimary(buyer, tokenId);

        vm.prank(buyer2);
        vm.expectRevert(TrustTicket.TicketUnavailable.selector);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);

        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.2 ether);

        vm.prank(buyer2);
        trustTicket.purchaseResaleTicket{value: 1.2 ether}(tokenId);

        assertEq(trustTicket.ownerOf(tokenId), buyer2);
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

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.TicketListedError.selector);
        trustTicket.listTicket(tokenId, 1 ether);
    }

    function testCannotTransferListedTicketOutsideOfficialMarketplace() public {
        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.1 ether);

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.TicketListedError.selector);
        trustTicket.transferFrom(buyer, buyer2, tokenId);
    }

    function testResalePurchaseClearsListingTransfersTicketAndPaysSeller() public {
        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.1 ether);

        uint256 sellerBalanceBefore = buyer.balance;
        vm.prank(buyer2);
        trustTicket.purchaseResaleTicket{value: 1.1 ether}(tokenId);

        assertEq(trustTicket.ownerOf(tokenId), buyer2);
        assertEq(buyer.balance, sellerBalanceBefore + 1.1 ether);
        assertFalse(trustTicket.isTicketListed(tokenId));

        TrustTicket.ListingInfo memory listing = trustTicket.getListingInfo(tokenId);
        assertFalse(listing.active);
        assertEq(listing.price, 0);
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

    function testCancelListingOnlyOwnerAndUsedTicketsCannotRemainListed() public {
        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.1 ether);

        vm.prank(stranger);
        vm.expectRevert(TrustTicket.NotTicketOwner.selector);
        trustTicket.cancelListing(tokenId);

        vm.prank(buyer);
        trustTicket.cancelListing(tokenId);
        assertFalse(trustTicket.isTicketListed(tokenId));

        vm.prank(buyer);
        trustTicket.listTicket(tokenId, 1.1 ether);
        vm.prank(organizer);
        trustTicket.addEventValidator(eventId, validator);
        vm.prank(validator);
        trustTicket.useTicket(tokenId);

        assertFalse(trustTicket.isTicketListed(tokenId));
        TrustTicket.TicketInfo memory ticket = trustTicket.getTicketInfo(tokenId);
        assertTrue(ticket.used);
    }

    function testUsedTicketCannotTransferListOrBeResold() public {
        _buyPrimary(buyer, tokenId);
        vm.prank(organizer);
        trustTicket.addEventValidator(eventId, validator);
        vm.prank(validator);
        trustTicket.useTicket(tokenId);

        vm.prank(buyer);
        vm.expectRevert(TrustTicket.TicketUsedError.selector);
        trustTicket.transferFrom(buyer, buyer2, tokenId);

        vm.warp(resaleStart);
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.TicketUsedError.selector);
        trustTicket.listTicket(tokenId, 1 ether);
    }

    function testValidatorPermissionsGlobalAndEventScoped() public {
        _buyPrimary(buyer, tokenId);

        vm.prank(stranger);
        vm.expectRevert(TrustTicket.NotValidator.selector);
        trustTicket.useTicket(tokenId);

        vm.prank(otherOrganizer);
        vm.expectRevert(TrustTicket.NotEventOrganizer.selector);
        trustTicket.addEventValidator(eventId, validator);

        vm.prank(organizer);
        trustTicket.addEventValidator(eventId, validator);
        vm.prank(validator);
        trustTicket.useTicket(tokenId);

        vm.prank(organizer);
        uint256 secondToken = trustTicket.mintTicket(eventId, "A-2");
        _buyPrimary(buyer2, secondToken);

        vm.prank(admin);
        trustTicket.addValidator(stranger);
        vm.prank(stranger);
        trustTicket.useTicket(secondToken);
    }

    function testAdminOrOrganizerCanChangeEventStatus() public {
        vm.prank(stranger);
        vm.expectRevert(TrustTicket.NotEventOrganizer.selector);
        trustTicket.setEventStatus(eventId, false);

        vm.prank(admin);
        trustTicket.setEventStatus(eventId, false);

        vm.warp(primaryStart);
        vm.prank(buyer);
        vm.expectRevert(TrustTicket.EventInactive.selector);
        trustTicket.purchaseTicket{value: 1 ether}(tokenId);
    }

    function testPaymentFailureRevertsPrimaryAndResale() public {
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
        vm.expectRevert(TrustTicket.PaymentTransferFailed.selector);
        trustTicket.purchaseTicket{value: 1 ether}(rejectingToken);

        _buyPrimary(buyer, tokenId);
        vm.warp(resaleStart);
        vm.prank(buyer);
        trustTicket.transferFrom(buyer, address(rejectingOrganizer), tokenId);

        vm.prank(address(rejectingOrganizer));
        trustTicket.listTicket(tokenId, 1 ether);
        vm.prank(buyer2);
        vm.expectRevert(TrustTicket.PaymentTransferFailed.selector);
        trustTicket.purchaseResaleTicket{value: 1 ether}(tokenId);
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
}
