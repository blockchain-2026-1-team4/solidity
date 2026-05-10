// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
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

    function testValidSignedTicketVerification() public {
        uint256 buyerKey = 0xA11CE;
        address signingBuyer = vm.addr(buyerKey);
        vm.deal(signingBuyer, 10 ether);
        _buyPrimary(signingBuyer, tokenId);

        uint256 expiresAt = block.timestamp + 10 minutes;
        bytes memory signature = _signTicket(trustTicket, buyerKey, tokenId, signingBuyer, expiresAt);

        assertTrue(trustTicket.verifySignedTicket(tokenId, signingBuyer, expiresAt, signature));
    }

    function testExpiredSignedTicketVerificationReturnsFalse() public {
        uint256 buyerKey = 0xA11CE;
        address signingBuyer = vm.addr(buyerKey);
        vm.deal(signingBuyer, 10 ether);
        _buyPrimary(signingBuyer, tokenId);

        uint256 expiresAt = block.timestamp + 10 minutes;
        bytes memory signature = _signTicket(trustTicket, buyerKey, tokenId, signingBuyer, expiresAt);

        vm.warp(expiresAt + 1);
        assertFalse(trustTicket.verifySignedTicket(tokenId, signingBuyer, expiresAt, signature));
    }

    function testWrongSignerSignedTicketVerificationReturnsFalse() public {
        uint256 buyerKey = 0xA11CE;
        uint256 wrongSignerKey = 0xB0B;
        address signingBuyer = vm.addr(buyerKey);
        vm.deal(signingBuyer, 10 ether);
        _buyPrimary(signingBuyer, tokenId);

        uint256 expiresAt = block.timestamp + 10 minutes;
        bytes memory signature = _signTicket(trustTicket, wrongSignerKey, tokenId, signingBuyer, expiresAt);

        assertFalse(trustTicket.verifySignedTicket(tokenId, signingBuyer, expiresAt, signature));
    }

    function testPreviousOwnerSignatureInvalidAfterResale() public {
        uint256 buyer1Key = 0xA11CE;
        uint256 buyer2Key = 0xB0B;
        address signingBuyer1 = vm.addr(buyer1Key);
        address signingBuyer2 = vm.addr(buyer2Key);
        vm.deal(signingBuyer1, 10 ether);
        vm.deal(signingBuyer2, 10 ether);

        _buyPrimary(signingBuyer1, tokenId);
        uint256 expiresAt = resaleStart + 10 minutes;
        bytes memory buyer1Signature = _signTicket(trustTicket, buyer1Key, tokenId, signingBuyer1, expiresAt);

        vm.warp(resaleStart);
        vm.prank(signingBuyer1);
        trustTicket.listTicket(tokenId, 1.1 ether);
        vm.prank(signingBuyer2);
        trustTicket.purchaseResaleTicket{value: 1.1 ether}(tokenId);

        bytes memory buyer2Signature = _signTicket(trustTicket, buyer2Key, tokenId, signingBuyer2, expiresAt);

        assertFalse(trustTicket.verifySignedTicket(tokenId, signingBuyer1, expiresAt, buyer1Signature));
        assertTrue(trustTicket.verifySignedTicket(tokenId, signingBuyer2, expiresAt, buyer2Signature));
    }

    function testUsedTicketSignedVerificationReturnsFalse() public {
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

    function testFullTicketLifecycleDemo() public {
        TrustTicket demoTicket = new TrustTicket(admin);
        address buyer1 = address(0x1111);
        uint256 demoBuyer2Key = 0x2222;
        address demoBuyer2 = vm.addr(demoBuyer2Key);
        address demoValidator = address(0x3333);
        uint256 demoPrimaryStart = block.timestamp + 1 days;
        uint256 demoPrimaryEnd = demoPrimaryStart + 7 days;
        uint256 demoResaleStart = demoPrimaryStart + 1 days;
        uint256 demoResaleEnd = demoPrimaryEnd + 10 days;
        uint256 demoPrice = 0.1 ether;
        uint256 demoResalePrice = 0.11 ether;

        vm.deal(buyer1, 10 ether);
        vm.deal(demoBuyer2, 10 ether);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 1. 관리자 계정이 주최자 권한을 부여합니다");
        console2.log(unicode"주최자 주소:", organizer);
        vm.prank(admin);
        demoTicket.addOrganizer(organizer);
        bool organizerRole = demoTicket.hasRole(demoTicket.ORGANIZER_ROLE(), organizer);
        console2.log(unicode"주최자 권한 부여 결과:", organizerRole);
        assertTrue(organizerRole);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 2. 주최자가 이벤트를 생성합니다");
        vm.prank(organizer);
        uint256 demoEventId = demoTicket.createEvent(
            "Indie Concert",
            block.timestamp + 30 days,
            demoPrice,
            2,
            demoPrimaryStart,
            demoPrimaryEnd,
            true,
            12_000,
            demoResaleStart,
            demoResaleEnd
        );
        TrustTicket.EventInfo memory demoEvent = demoTicket.getEventInfo(demoEventId);
        console2.log(unicode"생성된 이벤트 ID:", demoEvent.eventId);
        console2.log(unicode"이벤트명:", demoEvent.eventName);
        console2.log(unicode"티켓 가격:", demoEvent.ticketPrice);
        console2.log(unicode"총 티켓 수량:", demoEvent.totalTicketCount);
        console2.log(unicode"남은 티켓 수량:", demoEvent.remainingTicketCount);
        assertEq(demoEvent.eventName, "Indie Concert");
        assertEq(demoEvent.ticketPrice, demoPrice);
        assertEq(demoEvent.totalTicketCount, 2);
        assertEq(demoEvent.remainingTicketCount, 2);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 3. 주최자가 NFT 티켓을 발행합니다");
        vm.prank(organizer);
        uint256 demoTokenId = demoTicket.mintTicket(demoEventId, "A-1");
        TrustTicket.TicketInfo memory demoTicketInfo = demoTicket.getTicketInfo(demoTokenId);
        console2.log(unicode"발행된 티켓 tokenId:", demoTicketInfo.tokenId);
        console2.log(unicode"연결된 이벤트 ID:", demoTicketInfo.eventId);
        console2.log(unicode"좌석 정보:", demoTicketInfo.seatInfo);
        console2.log(unicode"원가:", demoTicketInfo.originalPrice);
        console2.log(unicode"사용 여부:", demoTicketInfo.used);
        console2.log(unicode"리셀 등록 여부:", demoTicketInfo.listed);
        console2.log(unicode"구매 전 티켓 소유자:", demoTicket.ownerOf(demoTokenId));
        assertEq(demoTicket.ownerOf(demoTokenId), address(demoTicket));
        assertFalse(demoTicketInfo.used);
        assertFalse(demoTicketInfo.listed);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 4. 구매자1이 1차 판매 티켓을 구매합니다");
        vm.warp(demoPrimaryStart);
        console2.log(unicode"구매자1 주소:", buyer1);
        vm.prank(buyer1);
        demoTicket.purchaseTicket{value: demoPrice}(demoTokenId);
        demoEvent = demoTicket.getEventInfo(demoEventId);
        console2.log(unicode"구매 후 티켓 소유자:", demoTicket.ownerOf(demoTokenId));
        console2.log(unicode"구매 후 남은 티켓 수량:", demoEvent.remainingTicketCount);
        assertEq(demoTicket.ownerOf(demoTokenId), buyer1);
        assertEq(demoEvent.remainingTicketCount, 1);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 5. 구매자1이 티켓을 공식 리셀 마켓에 등록합니다");
        vm.warp(demoResaleStart);
        console2.log(unicode"판매자 주소:", buyer1);
        console2.log(unicode"리셀 등록 가격:", demoResalePrice);
        vm.prank(buyer1);
        demoTicket.listTicket(demoTokenId, demoResalePrice);
        TrustTicket.ListingInfo memory demoListing = demoTicket.getListingInfo(demoTokenId);
        console2.log(unicode"리셀 등록 여부:", demoTicket.isTicketListed(demoTokenId));
        console2.log(unicode"리셀 판매자:", demoListing.seller);
        console2.log(unicode"리셀 판매 활성 상태:", demoListing.active);
        assertTrue(demoTicket.isTicketListed(demoTokenId));
        assertEq(demoListing.seller, buyer1);
        assertTrue(demoListing.active);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 6. 구매자2가 리셀 티켓을 구매합니다");
        console2.log(unicode"구매자2 주소:", demoBuyer2);
        vm.prank(demoBuyer2);
        demoTicket.purchaseResaleTicket{value: demoResalePrice}(demoTokenId);
        console2.log(unicode"리셀 구매 후 티켓 소유자:", demoTicket.ownerOf(demoTokenId));
        console2.log(unicode"리셀 구매 후 등록 상태:", demoTicket.isTicketListed(demoTokenId));
        assertEq(demoTicket.ownerOf(demoTokenId), demoBuyer2);
        assertFalse(demoTicket.isTicketListed(demoTokenId));

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 7. 구매자2가 만료시간이 포함된 서명 QR을 생성했다고 가정하고 검증합니다");
        uint256 demoExpiresAt = block.timestamp + 10 minutes;
        bytes memory demoSignature = _signTicket(demoTicket, demoBuyer2Key, demoTokenId, demoBuyer2, demoExpiresAt);
        bool signedQrValidBeforeCheckIn =
            demoTicket.verifySignedTicket(demoTokenId, demoBuyer2, demoExpiresAt, demoSignature);
        console2.log(unicode"QR에 적힌 소유자:", demoBuyer2);
        console2.log(unicode"QR 만료 시간:", demoExpiresAt);
        console2.log(unicode"체크인 전 서명 QR 검증 결과:", signedQrValidBeforeCheckIn);
        assertTrue(signedQrValidBeforeCheckIn);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 8. 주최자가 체크인 검증자를 등록합니다");
        console2.log(unicode"검증자 주소:", demoValidator);
        vm.prank(organizer);
        demoTicket.addEventValidator(demoEventId, demoValidator);
        console2.log(unicode"검증자 등록 완료");

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 9. 검증자가 행사 입장 체크인을 처리합니다");
        vm.prank(demoValidator);
        demoTicket.useTicket(demoTokenId);
        demoTicketInfo = demoTicket.getTicketInfo(demoTokenId);
        bool signedQrValidAfterCheckIn =
            demoTicket.verifySignedTicket(demoTokenId, demoBuyer2, demoExpiresAt, demoSignature);
        console2.log(unicode"체크인 후 사용 여부:", demoTicketInfo.used);
        console2.log(unicode"체크인 후 티켓 유효 여부:", demoTicket.isTicketValid(demoTokenId));
        console2.log(unicode"체크인 후 서명 QR 검증 결과:", signedQrValidAfterCheckIn);
        assertTrue(demoTicketInfo.used);
        assertFalse(demoTicket.isTicketValid(demoTokenId));
        assertFalse(signedQrValidAfterCheckIn);

        console2.log("--------------------------------------------------");
        console2.log(unicode"STEP 10. 사용 완료된 티켓은 재판매할 수 없습니다");
        vm.prank(demoBuyer2);
        vm.expectRevert(TrustTicket.TicketUsedError.selector);
        demoTicket.listTicket(demoTokenId, demoResalePrice);
        console2.log(unicode"예상대로 재판매 시도가 거부되었습니다");
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
